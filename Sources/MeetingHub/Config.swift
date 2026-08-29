import Foundation
import MeetingCore
import Vapor

enum HubVersion {
    static let string = "0.1.0"
}

/// `config.json` in the data directory. Everything else is in the database.
struct HubConfig: Codable {
    var name: String = "Meeting Hub"
    var port: Int = 8787
    /// Address to listen on. Connections are still filtered by `RemoteAllowlistMiddleware`.
    var bind: String = "0.0.0.0"
    /// Extra CIDRs allowed to connect, on top of localhost and the Tailscale range (100.64.0.0/10).
    var allowedCIDRs: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Meeting Hub"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8787
        bind = try c.decodeIfPresent(String.self, forKey: .bind) ?? "0.0.0.0"
        allowedCIDRs = try c.decodeIfPresent([String].self, forKey: .allowedCIDRs) ?? []
    }

    static func load(from url: URL) -> HubConfig {
        guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(HubConfig.self, from: data) else { return HubConfig() }
        return c
    }

    func save(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }
}

/// Where the hub keeps everything: `$MEETINGHUB_DATA`, else `~/MeetingHub`.
struct HubPaths {
    let root: URL

    var configFile: URL { root.appendingPathComponent("config.json") }
    var database: URL { root.appendingPathComponent("hub.sqlite") }
    var masterKey: URL { root.appendingPathComponent("master.key") }
    var audio: URL { root.appendingPathComponent("audio", isDirectory: true) }
    var export: URL { root.appendingPathComponent("export", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    static func detect() -> HubPaths {
        if let env = ProcessInfo.processInfo.environment["MEETINGHUB_DATA"], !env.isEmpty {
            return HubPaths(root: URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true))
        }
        return HubPaths(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MeetingHub", isDirectory: true))
    }

    func ensure() throws {
        for dir in [root, audio, export, logs, tmp] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    func audioDir(workspace: UUID, meeting: UUID) -> URL {
        audio.appendingPathComponent(workspace.uuidString, isDirectory: true).appendingPathComponent(meeting.uuidString, isDirectory: true)
    }
}

// MARK: - Application storage

struct HubPathsKey: StorageKey { typealias Value = HubPaths }
struct HubConfigKey: StorageKey { typealias Value = HubConfig }
struct SecretsKey: StorageKey { typealias Value = Secrets }
struct EventBusKey: StorageKey { typealias Value = EventBus }
struct JobRunnerKey: StorageKey { typealias Value = JobRunner }

extension Application {
    var hubPaths: HubPaths {
        get { storage[HubPathsKey.self]! }
        set { storage[HubPathsKey.self] = newValue }
    }
    var hubConfig: HubConfig {
        get { storage[HubConfigKey.self]! }
        set { storage[HubConfigKey.self] = newValue }
    }
    var secrets: Secrets {
        get { storage[SecretsKey.self]! }
        set { storage[SecretsKey.self] = newValue }
    }
    var eventBus: EventBus {
        get { storage[EventBusKey.self]! }
        set { storage[EventBusKey.self] = newValue }
    }
    var jobRunner: JobRunner {
        get { storage[JobRunnerKey.self]! }
        set { storage[JobRunnerKey.self] = newValue }
    }
    var hubInfo: HubInfoProvider { HubInfoProvider(app: self) }
}

struct HubInfoProvider {
    let app: Application
    var info: HubInfo {
        #if os(macOS)
        let platform = "macOS", local = true
        #elseif os(Linux)
        let platform = "Linux", local = false
        #else
        let platform = "unknown", local = false
        #endif
        return HubInfo(name: app.hubConfig.name, version: HubVersion.string, platform: platform, localTranscription: local)
    }
}

// MARK: - Network facts (for pairing codes and bind addresses)

enum NetworkInfo {
    /// Prefer the Tailscale MagicDNS name, then the Tailscale IP, then any LAN IPv4, then the hostname.
    static func pairingHost() -> String {
        let ts = tailscale()
        if let name = ts.dnsName, !name.isEmpty { return name }
        if let ip = ts.ip { return ip }
        if let ip = interfaceIPv4s().first(where: { isTailscale($0) }) { return ip }
        if let ip = interfaceIPv4s().first(where: { !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.") }) { return ip }
        return ProcessInfo.processInfo.hostName
    }

    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func tailscale() -> (dnsName: String?, ip: String?) {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale",
                          "/opt/homebrew/bin/tailscale", "/usr/bin/tailscale"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return (nil, nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["status", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return (nil, nil) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = obj["Self"] as? [String: Any] else { return (nil, nil) }
        var dns = me["DNSName"] as? String
        if dns?.hasSuffix(".") == true { dns?.removeLast() }
        let ip = (me["TailscaleIPs"] as? [String])?.first { $0.contains(".") }
        return (dns, ip)
    }

    static func interfaceIPv4s() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}
