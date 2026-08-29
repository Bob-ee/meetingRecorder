import Foundation

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct ActionItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var task: String
    public var owner: String?
    public var due: String?
    public var done: Bool
    public var isManual: Bool

    public init(id: UUID = UUID(), task: String, owner: String? = nil, due: String? = nil, done: Bool = false, isManual: Bool = false) {
        self.id = id; self.task = task; self.owner = owner; self.due = due; self.done = done; self.isManual = isManual
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
    }
}

public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    case recording, recorded, uploading, queued, transcribing, transcribed, summarizing, ready, failed

    public var label: String {
        switch self {
        case .recording: return "Recording"
        case .recorded: return "Recorded"
        case .uploading: return "Uploading"
        case .queued: return "Queued"
        case .transcribing: return "Transcribing"
        case .transcribed: return "Transcribed"
        case .summarizing: return "Summarizing"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    /// Something is actively happening to the meeting (spinner-worthy).
    public var isBusy: Bool {
        switch self {
        case .uploading, .queued, .transcribing, .summarizing: return true
        default: return false
        }
    }
}

public enum MeetingSource: String, Codable, Sendable { case live, imported }

public struct Meeting: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var titleIsAuto: Bool
    public var startedAt: Date
    public var durationSeconds: Double
    public var status: MeetingStatus
    public var source: MeetingSource
    public var actionItems: [ActionItem]
    public var speakerNames: [String: String]
    public var errorMessage: String?
    public var importedFileName: String?
    public var updatedAt: Date

    public init(id: UUID = UUID(), projectID: UUID, title: String, titleIsAuto: Bool = true,
                startedAt: Date = Date(), durationSeconds: Double = 0, status: MeetingStatus = .recorded,
                source: MeetingSource = .live, actionItems: [ActionItem] = [], speakerNames: [String: String] = [:],
                errorMessage: String? = nil, importedFileName: String? = nil, updatedAt: Date? = nil) {
        self.id = id; self.projectID = projectID; self.title = title; self.titleIsAuto = titleIsAuto
        self.startedAt = startedAt; self.durationSeconds = durationSeconds; self.status = status
        self.source = source; self.actionItems = actionItems; self.speakerNames = speakerNames
        self.errorMessage = errorMessage; self.importedFileName = importedFileName
        self.updatedAt = updatedAt ?? startedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        projectID = try c.decode(UUID.self, forKey: .projectID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Meeting"
        titleIsAuto = try c.decodeIfPresent(Bool.self, forKey: .titleIsAuto) ?? false
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        status = try c.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .recorded
        source = try c.decodeIfPresent(MeetingSource.self, forKey: .source) ?? .live
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        importedFileName = try c.decodeIfPresent(String.self, forKey: .importedFileName)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? startedAt
    }

    public var openActionItems: [ActionItem] { actionItems.filter { !$0.done } }

    public func displayName(forSpeaker speaker: String) -> String {
        speakerNames[speaker] ?? speaker
    }
}

public struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: UUID = UUID(), speaker: String, start: Double, end: Double, text: String) {
        self.id = id; self.speaker = speaker; self.start = start; self.end = end; self.text = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? "Speaker"
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

/// What the language model returns for a meeting. Decoding is lenient: any missing field becomes empty.
public struct MeetingSummary: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var owner: String?
        public var task: String
        public var due: String?

        public init(owner: String? = nil, task: String, due: String? = nil) {
            self.owner = owner; self.task = task; self.due = due
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            owner = try? c.decodeIfPresent(String.self, forKey: .owner)
            task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
            due = try? c.decodeIfPresent(String.self, forKey: .due)
        }
    }

    public var title: String?
    public var summary: String
    public var decisions: [String]
    public var actionItems: [Item]
    public var openQuestions: [String]

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    public init(title: String? = nil, summary: String, decisions: [String] = [], actionItems: [Item] = [], openQuestions: [String] = []) {
        self.title = title; self.summary = summary; self.decisions = decisions
        self.actionItems = actionItems; self.openQuestions = openQuestions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        decisions = (try? c.decodeIfPresent([String].self, forKey: .decisions)) ?? []
        actionItems = (try? c.decodeIfPresent([Item].self, forKey: .actionItems)) ?? []
        openQuestions = (try? c.decodeIfPresent([String].self, forKey: .openQuestions)) ?? []
    }
}
