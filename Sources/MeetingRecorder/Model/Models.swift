import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}

struct ActionItem: Identifiable, Codable, Hashable {
    var id: UUID
    var task: String
    var owner: String?
    var due: String?
    var done: Bool
    var isManual: Bool

    init(id: UUID = UUID(), task: String, owner: String? = nil, due: String? = nil, done: Bool = false, isManual: Bool = false) {
        self.id = id; self.task = task; self.owner = owner; self.due = due; self.done = done; self.isManual = isManual
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
    }
}

enum MeetingStatus: String, Codable {
    case recording, recorded, transcribing, transcribed, summarizing, ready, failed

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .recorded: return "Recorded"
        case .transcribing: return "Transcribing"
        case .transcribed: return "Transcribed"
        case .summarizing: return "Summarizing"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    var isBusy: Bool { self == .transcribing || self == .summarizing }
}

enum MeetingSource: String, Codable { case live, imported }

struct Meeting: Identifiable, Codable, Hashable {
    var id: UUID
    var projectID: UUID
    var title: String
    var titleIsAuto: Bool
    var startedAt: Date
    var durationSeconds: Double
    var status: MeetingStatus
    var source: MeetingSource
    var actionItems: [ActionItem]
    var speakerNames: [String: String]
    var errorMessage: String?
    var importedFileName: String?

    init(id: UUID = UUID(), projectID: UUID, title: String, titleIsAuto: Bool = true,
         startedAt: Date = Date(), durationSeconds: Double = 0, status: MeetingStatus = .recorded,
         source: MeetingSource = .live, actionItems: [ActionItem] = [], speakerNames: [String: String] = [:],
         errorMessage: String? = nil, importedFileName: String? = nil) {
        self.id = id; self.projectID = projectID; self.title = title; self.titleIsAuto = titleIsAuto
        self.startedAt = startedAt; self.durationSeconds = durationSeconds; self.status = status
        self.source = source; self.actionItems = actionItems; self.speakerNames = speakerNames
        self.errorMessage = errorMessage; self.importedFileName = importedFileName
    }

    init(from decoder: Decoder) throws {
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
    }

    var openActionItems: [ActionItem] { actionItems.filter { !$0.done } }

    func displayName(forSpeaker speaker: String) -> String {
        speakerNames[speaker] ?? speaker
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable {
    var id: UUID
    var speaker: String
    var start: Double
    var end: Double
    var text: String

    init(id: UUID = UUID(), speaker: String, start: Double, end: Double, text: String) {
        self.id = id; self.speaker = speaker; self.start = start; self.end = end; self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? "Speaker"
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

/// What Claude returns for a meeting.
struct MeetingSummary: Codable {
    struct Item: Codable {
        var owner: String?
        var task: String
        var due: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            owner = try? c.decodeIfPresent(String.self, forKey: .owner)
            task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
            due = try? c.decodeIfPresent(String.self, forKey: .due)
        }
    }

    var title: String?
    var summary: String
    var decisions: [String]
    var actionItems: [Item]
    var openQuestions: [String]

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        decisions = (try? c.decodeIfPresent([String].self, forKey: .decisions)) ?? []
        actionItems = (try? c.decodeIfPresent([Item].self, forKey: .actionItems)) ?? []
        openQuestions = (try? c.decodeIfPresent([String].self, forKey: .openQuestions)) ?? []
    }
}
