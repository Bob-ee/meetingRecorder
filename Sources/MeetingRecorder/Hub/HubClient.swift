import Foundation
import CryptoKit
import MeetingCore

enum HubClientError: LocalizedError {
    case badURL
    case http(Int, String)
    case notPaired

    var errorDescription: String? {
        switch self {
        case .badURL: return "The pairing code doesn't contain a valid address"
        case .http(let code, let reason): return "Hub replied \(code): \(reason)"
        case .notPaired: return "Not connected to a hub — paste a pairing code in Settings"
        }
    }

    var isUnauthorized: Bool { if case .http(401, _) = self { return true } else { return false } }
}

/// Thin async client for the hub API. One instance per (baseURL, token).
struct HubClient: Sendable {
    let baseURL: URL
    let token: String
    private let session: URLSession

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    init?(pairingCode: String) {
        guard let code = PairingCode(parsing: pairingCode), let url = code.baseURL else { return nil }
        self.init(baseURL: url, token: code.token)
    }

    // MARK: Requests

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                         headers: [String: String] = [:]) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/" + path), resolvingAgainstBaseURL: false) else {
            throw HubClientError.badURL
        }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw HubClientError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            var reason = String(decoding: data.prefix(300), as: UTF8.self)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let r = obj["reason"] as? String { reason = r }
            throw HubClientError.http(http.statusCode, reason)
        }
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                    body: (any Encodable)? = nil) async throws -> T {
        let data = try body.map { try wireEncoder.encode($0) }
        let (respData, response) = try await session.data(for: request(method, path, query: query, body: data))
        try check(respData, response)
        return try jsonDecoder.decode(T.self, from: respData)
    }

    private func sendNoContent(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws {
        let data = try body.map { try wireEncoder.encode($0) }
        let (respData, response) = try await session.data(for: request(method, path, body: data))
        try check(respData, response)
    }

    // MARK: Endpoints

    func health() async throws -> HubInfo { try await send("GET", "health") }
    func me() async throws -> WhoAmI { try await send("GET", "me") }
    func capabilities() async throws -> Capabilities { try await send("GET", "capabilities") }

    func projects() async throws -> [ProjectDetail] { try await send("GET", "projects") }
    func createProject(_ r: CreateProjectRequest) async throws -> ProjectDetail { try await send("POST", "projects", body: r) }
    func patchProject(_ id: UUID, _ r: PatchProjectRequest) async throws -> ProjectDetail { try await send("PATCH", "projects/\(id.uuidString)", body: r) }
    func deleteProject(_ id: UUID) async throws { try await sendNoContent("DELETE", "projects/\(id.uuidString)") }

    func meetings(project: UUID? = nil, since: Date? = nil) async throws -> [Meeting] {
        var q: [String: String] = [:]
        if let project { q["project"] = project.uuidString }
        if let since { q["since"] = ISO8601DateFormatter().string(from: since) }
        return try await send("GET", "meetings", query: q)
    }
    func createMeeting(_ r: CreateMeetingRequest) async throws -> Meeting { try await send("POST", "meetings", body: r) }
    func meeting(_ id: UUID) async throws -> MeetingDetail { try await send("GET", "meetings/\(id.uuidString)") }
    func patchMeeting(_ id: UUID, _ r: PatchMeetingRequest) async throws -> Meeting { try await send("PATCH", "meetings/\(id.uuidString)", body: r) }
    func deleteMeeting(_ id: UUID) async throws { try await sendNoContent("DELETE", "meetings/\(id.uuidString)") }
    func replaceActionItems(_ id: UUID, _ items: [ActionItem]) async throws -> Meeting { try await send("PUT", "meetings/\(id.uuidString)/action-items", body: items) }
    func pushTranscript(_ id: UUID, _ segments: [TranscriptSegment]) async throws -> MeetingDetail { try await send("PUT", "meetings/\(id.uuidString)/transcript", body: segments) }
    func pushSummary(_ id: UUID, markdown: String) async throws -> MeetingDetail { try await send("PUT", "meetings/\(id.uuidString)/summary", body: PushSummaryRequest(markdown: markdown, provider: "Mac app")) }
    func process(_ id: UUID, steps: [JobStep]) async throws -> JobInfo { try await send("POST", "meetings/\(id.uuidString)/process", body: ProcessRequest(steps: steps)) }
    func job(_ id: UUID) async throws -> JobInfo { try await send("GET", "meetings/\(id.uuidString)/job") }
    func audio(_ id: UUID) async throws -> [AudioTrackInfo] { try await send("GET", "meetings/\(id.uuidString)/audio") }

    func settings() async throws -> HubSettings { try await send("GET", "settings") }
    func saveSettings(_ s: HubSettings) async throws -> HubSettings { try await send("PUT", "settings", body: s) }
    func testSettings(_ s: HubSettings?) async throws -> TestResult {
        let data = try s.map { try wireEncoder.encode($0) }
        var req = try request("POST", "settings/test", body: data)
        req.timeoutInterval = 180
        let (respData, response) = try await session.data(for: req)
        try check(respData, response)
        return try jsonDecoder.decode(TestResult.self, from: respData)
    }

    /// Streams a file straight from disk. Retries are just another PUT; the hub replaces the earlier copy.
    func upload(_ id: UUID, kind: AudioTrackKind, file: URL) async throws -> AudioTrackInfo {
        let sha = try Self.sha256(of: file)
        var req = try request("PUT", "meetings/\(id.uuidString)/audio/\(kind.rawValue)",
                              headers: [HubAPI.fileNameHeader: file.lastPathComponent, HubAPI.checksumHeader: sha,
                                        "Content-Type": "application/octet-stream"])
        req.timeoutInterval = 3600
        let (respData, response) = try await session.upload(for: req, fromFile: file)
        try check(respData, response)
        return try jsonDecoder.decode(AudioTrackInfo.self, from: respData)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Server-sent events. Ends (throws) when the connection drops; the caller reconnects.
    func events() -> AsyncThrowingStream<HubEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try request("GET", "events")
                    req.timeoutInterval = 3600
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw HubClientError.http(http.statusCode, "event stream refused")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let event = try? jsonDecoder.decode(HubEvent.self, from: Data(json.utf8)) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Error {
    /// True for "the hub can't be reached right now" as opposed to "the hub said no".
    var isConnectivityProblem: Bool {
        if let e = self as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .timedOut, .dnsLookupFailed, .internationalRoamingOff, .resourceUnavailable, .secureConnectionFailed:
                return true
            default: return false
            }
        }
        return false
    }
}
