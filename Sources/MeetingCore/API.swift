import Foundation

/// Wire types shared by the hub and every client. Bump `HubAPI.version` when a change isn't backward compatible.
public enum HubAPI {
    public static let version = 1
    public static let prefix = "/api/v1"
    public static let tokenHeader = "Authorization"
    public static let checksumHeader = "X-Content-SHA256"
    public static let fileNameHeader = "X-File-Name"
}

public struct HubInfo: Codable, Sendable {
    public var name: String
    public var version: String
    public var apiVersion: Int
    public var platform: String
    public var localTranscription: Bool

    public init(name: String, version: String, apiVersion: Int = HubAPI.version, platform: String, localTranscription: Bool) {
        self.name = name; self.version = version; self.apiVersion = apiVersion
        self.platform = platform; self.localTranscription = localTranscription
    }
}

public struct HubUser: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var email: String?
    public init(id: UUID, name: String, email: String? = nil) { self.id = id; self.name = name; self.email = email }
}

public struct HubWorkspace: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

public struct WhoAmI: Codable, Sendable {
    public var user: HubUser
    public var workspace: HubWorkspace
    public var device: String
    public var hub: HubInfo
    public init(user: HubUser, workspace: HubWorkspace, device: String, hub: HubInfo) {
        self.user = user; self.workspace = workspace; self.device = device; self.hub = hub
    }
}

// MARK: Projects

public struct ProjectDetail: Codable, Sendable, Identifiable {
    public var project: Project
    public var context: String
    public var meetingCount: Int
    public var id: UUID { project.id }
    public init(project: Project, context: String, meetingCount: Int) {
        self.project = project; self.context = context; self.meetingCount = meetingCount
    }
}

public struct CreateProjectRequest: Codable, Sendable {
    public var id: UUID?
    public var name: String
    public var context: String?
    public init(id: UUID? = nil, name: String, context: String? = nil) { self.id = id; self.name = name; self.context = context }
}

public struct PatchProjectRequest: Codable, Sendable {
    public var name: String?
    public var context: String?
    public init(name: String? = nil, context: String? = nil) { self.name = name; self.context = context }
}

// MARK: Meetings

public struct CreateMeetingRequest: Codable, Sendable {
    public var id: UUID?
    public var projectID: UUID
    public var title: String
    public var titleIsAuto: Bool
    public var startedAt: Date
    public var durationSeconds: Double
    public var source: MeetingSource
    public var importedFileName: String?

    public init(id: UUID? = nil, projectID: UUID, title: String, titleIsAuto: Bool = true, startedAt: Date,
                durationSeconds: Double, source: MeetingSource, importedFileName: String? = nil) {
        self.id = id; self.projectID = projectID; self.title = title; self.titleIsAuto = titleIsAuto
        self.startedAt = startedAt; self.durationSeconds = durationSeconds; self.source = source
        self.importedFileName = importedFileName
    }

    enum CodingKeys: String, CodingKey { case id, projectID, title, titleIsAuto, startedAt, durationSeconds, source, importedFileName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Meeting"
        titleIsAuto = try c.decodeIfPresent(Bool.self, forKey: .titleIsAuto) ?? true
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        source = try c.decodeIfPresent(MeetingSource.self, forKey: .source) ?? .live
        importedFileName = try c.decodeIfPresent(String.self, forKey: .importedFileName)
    }
}

public struct PatchMeetingRequest: Codable, Sendable {
    public var title: String?
    public var titleIsAuto: Bool?
    public var projectID: UUID?
    public var notes: String?
    public var speakerNames: [String: String]?
    public var durationSeconds: Double?
    public var startedAt: Date?

    public init(title: String? = nil, titleIsAuto: Bool? = nil, projectID: UUID? = nil, notes: String? = nil,
                speakerNames: [String: String]? = nil, durationSeconds: Double? = nil, startedAt: Date? = nil) {
        self.title = title; self.titleIsAuto = titleIsAuto; self.projectID = projectID; self.notes = notes
        self.speakerNames = speakerNames; self.durationSeconds = durationSeconds; self.startedAt = startedAt
    }
}

public enum AudioTrackKind: String, Codable, Sendable, CaseIterable {
    case mic, system, imported = "import"
}

public struct AudioTrackInfo: Codable, Sendable {
    public var kind: AudioTrackKind
    public var fileName: String
    public var byteSize: Int
    public var sha256: String?
    public init(kind: AudioTrackKind, fileName: String, byteSize: Int, sha256: String? = nil) {
        self.kind = kind; self.fileName = fileName; self.byteSize = byteSize; self.sha256 = sha256
    }
}

public struct MeetingDetail: Codable, Sendable {
    public var meeting: Meeting
    public var projectName: String
    public var transcript: [TranscriptSegment]
    public var summaryMarkdown: String?
    public var notes: String
    public var audio: [AudioTrackInfo]
    public var job: JobInfo?

    public init(meeting: Meeting, projectName: String, transcript: [TranscriptSegment], summaryMarkdown: String?,
                notes: String, audio: [AudioTrackInfo], job: JobInfo?) {
        self.meeting = meeting; self.projectName = projectName; self.transcript = transcript
        self.summaryMarkdown = summaryMarkdown; self.notes = notes; self.audio = audio; self.job = job
    }
}

public struct NewActionItemRequest: Codable, Sendable {
    public var task: String
    public var owner: String?
    public var due: String?
    public init(task: String, owner: String? = nil, due: String? = nil) { self.task = task; self.owner = owner; self.due = due }
}

public struct PatchActionItemRequest: Codable, Sendable {
    public var task: String?
    public var owner: String?
    public var due: String?
    public var done: Bool?
    public init(task: String? = nil, owner: String? = nil, due: String? = nil, done: Bool? = nil) {
        self.task = task; self.owner = owner; self.due = due; self.done = done
    }
}

// MARK: Jobs

public enum JobStatus: String, Codable, Sendable { case queued, running, done, failed }
public enum JobStep: String, Codable, Sendable, CaseIterable { case transcribe, summarize }

public struct JobInfo: Codable, Sendable, Identifiable {
    public var id: UUID
    public var meetingID: UUID
    public var steps: [JobStep]
    public var status: JobStatus
    public var progress: String?
    public var error: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(id: UUID, meetingID: UUID, steps: [JobStep], status: JobStatus, progress: String? = nil, error: String? = nil,
                createdAt: Date, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id; self.meetingID = meetingID; self.steps = steps; self.status = status; self.progress = progress
        self.error = error; self.createdAt = createdAt; self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public struct ProcessRequest: Codable, Sendable {
    public var steps: [JobStep]
    public init(steps: [JobStep] = JobStep.allCases) { self.steps = steps }
}

// MARK: Settings

public struct HubSettings: Codable, Sendable, Equatable {
    /// Secrets arrive redacted; send them back unchanged to keep the stored value.
    public var summarizer: SummarizerSettings
    /// "v3" or "v2"
    public var asrVersion: String
    /// The workspace owner's display name — how their own voice is labeled in transcripts.
    public var userName: String

    public init(summarizer: SummarizerSettings, asrVersion: String = "v3", userName: String) {
        self.summarizer = summarizer; self.asrVersion = asrVersion; self.userName = userName
    }
}

public struct Capabilities: Codable, Sendable {
    public var providers: [ProviderDescription]
    public var transcriptionEngines: [String]
    public var hub: HubInfo
    public init(providers: [ProviderDescription], transcriptionEngines: [String], hub: HubInfo) {
        self.providers = providers; self.transcriptionEngines = transcriptionEngines; self.hub = hub
    }
}

public struct TestResult: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var elapsedSeconds: Double
    public init(ok: Bool, message: String, elapsedSeconds: Double) { self.ok = ok; self.message = message; self.elapsedSeconds = elapsedSeconds }
}

// MARK: Events (server-sent)

public enum HubEventKind: String, Codable, Sendable {
    case ping, meetingUpdated, meetingDeleted, projectUpdated, projectDeleted, jobUpdated, settingsUpdated
}

public struct HubEvent: Codable, Sendable {
    public var kind: HubEventKind
    public var meetingID: UUID?
    public var projectID: UUID?
    public var job: JobInfo?
    public var at: Date

    public init(kind: HubEventKind, meetingID: UUID? = nil, projectID: UUID? = nil, job: JobInfo? = nil, at: Date = Date()) {
        self.kind = kind; self.meetingID = meetingID; self.projectID = projectID; self.job = job; self.at = at
    }
}

// MARK: Pairing

/// `mh1:<host>:<port>:<token>` — one string to paste into a client. Hosts may contain colons only if bracketed (IPv6).
public struct PairingCode: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var token: String
    public var tls: Bool

    public init(host: String, port: Int, token: String, tls: Bool = false) {
        self.host = host; self.port = port; self.token = token; self.tls = tls
    }

    public var string: String { "\(tls ? "mh1s" : "mh1"):\(host):\(port):\(token)" }

    public var baseURL: URL? { URL(string: "\(tls ? "https" : "http")://\(host):\(port)") }

    public init?(parsing raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "mh1" || parts[0] == "mh1s", let port = Int(parts[2]), !parts[3].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(host: parts[1], port: port, token: parts[3], tls: parts[0] == "mh1s")
    }
}
