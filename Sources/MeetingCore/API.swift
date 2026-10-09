import Foundation

/// Wire types shared by the hub and every client. Bump `HubAPI.version` when a change isn't backward compatible.
public enum HubAPI {
    /// 2 added the change feed (`/changes`, `/meetings/:id/edits`) that clients now sync through.
    public static let version = 2
    public static let prefix = "/api/v1"
    public static let tokenHeader = "Authorization"
    public static let checksumHeader = "X-Content-SHA256"
    public static let fileNameHeader = "X-File-Name"
    /// On an audio upload: a base64 `CreateMeetingRequest`, so the meeting is created if the hub hasn't seen it.
    public static let meetingHeader = "X-Meeting"
    /// On an audio upload: the steps to queue once the file is stored, comma separated (`transcribe,summarize`).
    public static let processHeader = "X-Process"
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
    /// CONTEXT.md — the user's own.
    public var context: String
    /// LEARNED.md — what the summarizer has worked out for itself.
    public var learnedContext: String
    public var meetingCount: Int
    public var id: UUID { project.id }
    public init(project: Project, context: String, learnedContext: String = "", meetingCount: Int) {
        self.project = project; self.context = context; self.learnedContext = learnedContext
        self.meetingCount = meetingCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decode(Project.self, forKey: .project)
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
        learnedContext = try c.decodeIfPresent(String.self, forKey: .learnedContext) ?? ""
        meetingCount = try c.decodeIfPresent(Int.self, forKey: .meetingCount) ?? 0
    }
}

public struct CreateProjectRequest: Codable, Sendable {
    public var id: UUID?
    public var name: String
    public var context: String?
    public var learnedContext: String?
    public init(id: UUID? = nil, name: String, context: String? = nil, learnedContext: String? = nil) {
        self.id = id; self.name = name; self.context = context; self.learnedContext = learnedContext
    }
}

public struct PatchProjectRequest: Codable, Sendable {
    public var name: String?
    public var context: String?
    public var learnedContext: String?
    public init(name: String? = nil, context: String? = nil, learnedContext: String? = nil) {
        self.name = name; self.context = context; self.learnedContext = learnedContext
    }
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
    /// Replaces the meeting's suggested events (added-to-calendar and dismissed state included).
    public var events: [MeetingEvent]?

    public init(title: String? = nil, titleIsAuto: Bool? = nil, projectID: UUID? = nil, notes: String? = nil,
                speakerNames: [String: String]? = nil, durationSeconds: Double? = nil, startedAt: Date? = nil,
                events: [MeetingEvent]? = nil) {
        self.title = title; self.titleIsAuto = titleIsAuto; self.projectID = projectID; self.notes = notes
        self.speakerNames = speakerNames; self.durationSeconds = durationSeconds; self.startedAt = startedAt
        self.events = events
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

/// The reply to "suggest how to handle this action item".
public struct AdviceResponse: Codable, Sendable {
    public var itemID: UUID
    public var guidance: String
    public var generatedAt: Date
    public init(itemID: UUID, guidance: String, generatedAt: Date = Date()) {
        self.itemID = itemID; self.guidance = guidance; self.generatedAt = generatedAt
    }
}

public struct PushSummaryRequest: Codable, Sendable {
    public var markdown: String
    public var provider: String?
    public init(markdown: String, provider: String? = nil) { self.markdown = markdown; self.provider = provider }
}

// MARK: Sync

/// A meeting as devices edit and sync it: the meeting, the user's notes, and a tag that says whether the
/// transcript and summary a device has cached are still the current ones.
public struct MeetingRecord: Codable, Sendable, Equatable, Identifiable {
    public var meeting: Meeting
    public var notes: String
    /// Changes whenever the transcript or summary is rewritten; nil until there is either.
    public var contentTag: String?
    public var id: UUID { meeting.id }

    public init(meeting: Meeting, notes: String = "", contentTag: String? = nil) {
        self.meeting = meeting; self.notes = notes; self.contentTag = contentTag
    }
}

/// Everything one device changed about a meeting since it last heard from the hub, sent as one request and
/// applied as one write — so the reply is the meeting exactly as the hub holds it after this device's changes.
/// A nil field, or an empty list, means "unchanged".
public struct MeetingEdit: Codable, Sendable, Equatable {
    public var title: String?
    public var titleIsAuto: Bool?
    public var projectID: UUID?
    public var notes: String?
    /// The speakers this device renamed, each with its new name; an empty name puts the default label back.
    /// Speakers it didn't touch are left out, so two devices naming different speakers don't undo each other.
    public var speakerNames: [String: String]?
    /// Items this device created. Sent again after a lost reply, they update the copy that did arrive.
    public var addedItems: [ActionItem]
    /// Items this device edited. One that has since been removed on the hub stays removed.
    public var changedItems: [ActionItem]
    public var removedItems: [UUID]
    /// Suggested events whose "in calendar" or "dismissed" state this device changed.
    public var changedEvents: [MeetingEvent]

    public init(title: String? = nil, titleIsAuto: Bool? = nil, projectID: UUID? = nil, notes: String? = nil,
                speakerNames: [String: String]? = nil, addedItems: [ActionItem] = [], changedItems: [ActionItem] = [],
                removedItems: [UUID] = [], changedEvents: [MeetingEvent] = []) {
        self.title = title; self.titleIsAuto = titleIsAuto; self.projectID = projectID; self.notes = notes
        self.speakerNames = speakerNames; self.addedItems = addedItems; self.changedItems = changedItems
        self.removedItems = removedItems; self.changedEvents = changedEvents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        titleIsAuto = try c.decodeIfPresent(Bool.self, forKey: .titleIsAuto)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames)
        addedItems = try c.decodeIfPresent([ActionItem].self, forKey: .addedItems) ?? []
        changedItems = try c.decodeIfPresent([ActionItem].self, forKey: .changedItems) ?? []
        removedItems = try c.decodeIfPresent([UUID].self, forKey: .removedItems) ?? []
        changedEvents = try c.decodeIfPresent([MeetingEvent].self, forKey: .changedEvents) ?? []
    }

    public var isEmpty: Bool { self == MeetingEdit() }
}

/// Something that was deleted. Kept by the hub so a device that was away when it happened still finds out,
/// and so the hub can refuse to bring it back.
public struct Tombstone: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case project, meeting }
    public var kind: Kind
    public var id: UUID
    public init(kind: Kind, id: UUID) { self.kind = kind; self.id = id }
}

/// What changed in a workspace after a given revision. Every write on the hub takes the workspace's next
/// revision, so "everything after N" is exact — it doesn't depend on any device's clock.
public struct ChangeSet: Codable, Sendable {
    /// Pass this back as `since` next time.
    public var revision: Int64
    public var projects: [ProjectDetail]
    public var meetings: [MeetingRecord]
    public var removed: [Tombstone]
    /// There was more than one page; ask again from `revision`.
    public var hasMore: Bool

    public init(revision: Int64, projects: [ProjectDetail] = [], meetings: [MeetingRecord] = [],
                removed: [Tombstone] = [], hasMore: Bool = false) {
        self.revision = revision; self.projects = projects; self.meetings = meetings
        self.removed = removed; self.hasMore = hasMore
    }
}

/// A request for a pairing code for one more device, made from a device that is already paired.
public struct PairDeviceRequest: Codable, Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct PairDeviceResponse: Codable, Sendable {
    /// `mh1:<host>:<port>:<token>` — shown once; only its hash is kept.
    public var pairingCode: String
    public init(pairingCode: String) { self.pairingCode = pairingCode }
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

    /// The code as a link the apps open (`meetingrecorder://pair?code=…`), which is what a pairing QR holds —
    /// so pointing a phone's camera at it is the whole of pairing.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = PairingCode.urlScheme
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "code", value: string)]
        return components.url
    }

    public init?(url: URL) {
        guard url.scheme == PairingCode.urlScheme, url.host == "pair",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        self.init(parsing: code)
    }

    public static let urlScheme = "meetingrecorder"

    public init?(parsing raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "mh1" || parts[0] == "mh1s", let port = Int(parts[2]), !parts[3].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(host: parts[1], port: port, token: parts[3], tls: parts[0] == "mh1s")
    }
}
