import Foundation
import CryptoKit
import MeetingCore

public enum HubClientError: LocalizedError {
    case badURL
    case http(Int, String)
    case notPaired

    public var errorDescription: String? {
        switch self {
        case .badURL: return "The pairing code doesn't contain a valid address"
        case .http(let code, let reason): return "Hub replied \(code): \(reason)"
        case .notPaired: return "Not connected to a hub — paste a pairing code in Settings"
        }
    }

    public var status: Int? { if case .http(let code, _) = self { return code } else { return nil } }
    public var isUnauthorized: Bool { status == 401 }
    /// The hub has nothing by that id — it was never there, or it has been deleted.
    public var isNotFound: Bool { status == 404 }
    /// It was deleted on the hub, which will not take it back.
    public var isGone: Bool { status == 410 }
}

/// Thin async client for the hub API. One instance per (baseURL, token).
public struct HubClient: Sendable {
    public let baseURL: URL
    public let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public init?(pairingCode: String) {
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
        if let error = Self.error(status: http.statusCode, body: data) { throw error }
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

    public func health() async throws -> HubInfo { try await send("GET", "health") }
    public func me() async throws -> WhoAmI { try await send("GET", "me") }
    public func capabilities() async throws -> Capabilities { try await send("GET", "capabilities") }

    public func projects() async throws -> [ProjectDetail] { try await send("GET", "projects") }
    public func createProject(_ r: CreateProjectRequest) async throws -> ProjectDetail { try await send("POST", "projects", body: r) }
    public func patchProject(_ id: UUID, _ r: PatchProjectRequest) async throws -> ProjectDetail { try await send("PATCH", "projects/\(id.uuidString)", body: r) }
    public func deleteProject(_ id: UUID) async throws { try await sendNoContent("DELETE", "projects/\(id.uuidString)") }
    public func refreshProjectContext(_ id: UUID) async throws -> ProjectDetail {
        try await send("POST", "projects/\(id.uuidString)/context/refresh")
    }

    public func meetings(project: UUID? = nil, since: Date? = nil) async throws -> [Meeting] {
        var q: [String: String] = [:]
        if let project { q["project"] = project.uuidString }
        if let since { q["since"] = ISO8601DateFormatter().string(from: since) }
        return try await send("GET", "meetings", query: q)
    }
    public func createMeeting(_ r: CreateMeetingRequest) async throws -> Meeting { try await send("POST", "meetings", body: r) }
    public func meeting(_ id: UUID) async throws -> MeetingDetail { try await send("GET", "meetings/\(id.uuidString)") }
    public func patchMeeting(_ id: UUID, _ r: PatchMeetingRequest) async throws -> Meeting { try await send("PATCH", "meetings/\(id.uuidString)", body: r) }
    public func deleteMeeting(_ id: UUID) async throws { try await sendNoContent("DELETE", "meetings/\(id.uuidString)") }
    public func replaceActionItems(_ id: UUID, _ items: [ActionItem]) async throws -> Meeting { try await send("PUT", "meetings/\(id.uuidString)/action-items", body: items) }
    public func advise(meeting: UUID, item: UUID) async throws -> AdviceResponse {
        try await send("POST", "meetings/\(meeting.uuidString)/action-items/\(item.uuidString)/advise")
    }
    public func pushTranscript(_ id: UUID, _ segments: [TranscriptSegment]) async throws -> MeetingDetail { try await send("PUT", "meetings/\(id.uuidString)/transcript", body: segments) }
    public func pushSummary(_ id: UUID, markdown: String) async throws -> MeetingDetail { try await send("PUT", "meetings/\(id.uuidString)/summary", body: PushSummaryRequest(markdown: markdown, provider: "client")) }
    public func process(_ id: UUID, steps: [JobStep]) async throws -> JobInfo { try await send("POST", "meetings/\(id.uuidString)/process", body: ProcessRequest(steps: steps)) }
    public func job(_ id: UUID) async throws -> JobInfo { try await send("GET", "meetings/\(id.uuidString)/job") }

    /// Everything written on the hub after `revision`.
    public func changes(since revision: Int64) async throws -> ChangeSet {
        try await send("GET", "changes", query: ["since": String(revision)])
    }
    /// Send what this device changed about a meeting; the reply is the meeting as the hub now holds it.
    public func edit(_ id: UUID, _ edit: MeetingEdit) async throws -> MeetingRecord {
        try await send("POST", "meetings/\(id.uuidString)/edits", body: edit)
    }
    /// A pairing code for another device.
    public func pairDevice(named name: String) async throws -> PairingCode {
        let reply: PairDeviceResponse = try await send("POST", "devices", body: PairDeviceRequest(name: name))
        guard let code = PairingCode(parsing: reply.pairingCode) else { throw HubClientError.badURL }
        return code
    }
    public func audio(_ id: UUID) async throws -> [AudioTrackInfo] { try await send("GET", "meetings/\(id.uuidString)/audio") }

    public func settings() async throws -> HubSettings { try await send("GET", "settings") }
    public func saveSettings(_ s: HubSettings) async throws -> HubSettings { try await send("PUT", "settings", body: s) }
    public func testSettings(_ s: HubSettings?) async throws -> TestResult {
        let data = try s.map { try wireEncoder.encode($0) }
        var req = try request("POST", "settings/test", body: data)
        req.timeoutInterval = 180
        let (respData, response) = try await session.data(for: req)
        try check(respData, response)
        return try jsonDecoder.decode(TestResult.self, from: respData)
    }

    /// Streams a file straight from disk. Retries are just another PUT; the hub replaces the earlier copy.
    public func upload(_ id: UUID, kind: AudioTrackKind, file: URL) async throws -> AudioTrackInfo {
        var req = try uploadRequest(id, kind: kind, file: file)
        req.timeoutInterval = 3600
        let (respData, response) = try await session.upload(for: req, fromFile: file)
        try check(respData, response)
        return try jsonDecoder.decode(AudioTrackInfo.self, from: respData)
    }

    /// The request that uploads `file` as one of a meeting's tracks, for a caller that runs it on a session of
    /// its own (a background one, on a phone). With `creating`, the hub makes the meeting if it doesn't have it
    /// yet; with `process`, it queues those steps once the file is stored — so the one request is the whole job.
    public func uploadRequest(_ id: UUID, kind: AudioTrackKind, file: URL, creating meeting: CreateMeetingRequest? = nil,
                              process steps: [JobStep] = []) throws -> URLRequest {
        var headers = [HubAPI.fileNameHeader: file.lastPathComponent, HubAPI.checksumHeader: try Self.sha256(of: file),
                       "Content-Type": "application/octet-stream"]
        if let meeting { headers[HubAPI.meetingHeader] = try wireEncoder.encode(meeting).base64EncodedString() }
        if !steps.isEmpty { headers[HubAPI.processHeader] = steps.map(\.rawValue).joined(separator: ",") }
        return try request("PUT", "meetings/\(id.uuidString)/audio/\(kind.rawValue)", headers: headers)
    }

    /// What a response to a request run elsewhere means, in this client's terms.
    public static func error(status: Int, body: Data) -> HubClientError? {
        guard !(200..<300).contains(status) else { return nil }
        var reason = String(decoding: body.prefix(300), as: UTF8.self)
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let r = obj["reason"] as? String { reason = r }
        return .http(status, reason)
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Server-sent events. Ends (throws) when the connection drops; the caller reconnects.
    public func events() -> AsyncThrowingStream<HubEvent, Error> {
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

public extension Error {
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
