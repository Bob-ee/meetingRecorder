import Foundation

/// The hub as a per-user launchd service on macOS (starts at login, restarts if it dies).
enum LaunchAgent {
    static let label = "local.meetinghub"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func executablePath() -> String {
        if let url = Bundle.main.executableURL?.resolvingSymlinksInPath() { return url.path }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    static func install(paths: HubPaths) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath(), "serve"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "WorkingDirectory": paths.root.path,
            "StandardOutPath": paths.logs.appendingPathComponent("hub.log").path,
            "StandardErrorPath": paths.logs.appendingPathComponent("hub.log").path,
            "EnvironmentVariables": [
                "MEETINGHUB_DATA": paths.root.path,
                "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "HOME": home,
            ],
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        _ = launchctl(["bootout", domain, plistURL.path])   // ignore "not loaded"
        let (code, out) = launchctl(["bootstrap", domain, plistURL.path])
        if code != 0 { throw NSError(domain: "LaunchAgent", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(out)"]) }
    }

    static func uninstall() {
        _ = launchctl(["bootout", domain, plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    static func restart() -> Bool {
        launchctl(["kickstart", "-k", "\(domain)/\(label)"]).0 == 0
    }

    static func isRunning() -> Bool {
        let (code, out) = launchctl(["print", "\(domain)/\(label)"])
        return code == 0 && out.contains("state = running")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    private static var domain: String { "gui/\(getuid())" }

    @discardableResult
    static func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
