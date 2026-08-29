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

/// A moment the model pinned down from the transcript ("Friday" → an actual day). `hasTime` false means a whole day.
/// `timeZone` is where it was resolved, so a whole day stays the same calendar day on every device.
public struct EventDate: Codable, Hashable, Sendable {
    public var date: Date
    public var hasTime: Bool
    public var timeZone: String

    public init(date: Date, hasTime: Bool, timeZone: TimeZone = .current) {
        self.date = date; self.hasTime = hasTime; self.timeZone = timeZone.identifier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        hasTime = try c.decodeIfPresent(Bool.self, forKey: .hasTime) ?? false
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone) ?? TimeZone.current.identifier
    }

    public var tz: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    /// Year/month/day (plus hour/minute when timed) in the zone the date was resolved in.
    public var components: DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.dateComponents(hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
    }

    /// The same calendar day (and time) expressed in another zone — midnight there for whole days.
    public func date(in zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: components) ?? date
    }
}

public struct ActionItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var task: String
    public var owner: String?
    /// The deadline as it was said ("Friday", "end of month").
    public var due: String?
    /// That deadline resolved to a day (and time, if one was given), when the model could pin it down.
    public var dueDate: EventDate?
    public var done: Bool
    public var isManual: Bool
    /// When the user put this item in their calendar or reminders.
    public var calendarAddedAt: Date?

    public init(id: UUID = UUID(), task: String, owner: String? = nil, due: String? = nil, dueDate: EventDate? = nil,
                done: Bool = false, isManual: Bool = false, calendarAddedAt: Date? = nil) {
        self.id = id; self.task = task; self.owner = owner; self.due = due; self.dueDate = dueDate
        self.done = done; self.isManual = isManual; self.calendarAddedAt = calendarAddedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        dueDate = try? c.decodeIfPresent(EventDate.self, forKey: .dueDate)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        calendarAddedAt = try? c.decodeIfPresent(Date.self, forKey: .calendarAddedAt)
    }

    /// The deadline for display: the resolved day when there is one, else the words that were used.
    public var dueLabel: String? {
        if let dueDate { return Fmt.when(dueDate, end: nil, style: .short) }
        if let due, !due.isEmpty { return due }
        return nil
    }
}

/// Something the model found a date for in the conversation — a follow-up call, a demo, a launch, a trip — offered
/// to the user as a one-click calendar event. Lives with the meeting like action items do.
public struct MeetingEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var start: EventDate
    /// Only meaningful when `start.hasTime`.
    public var end: Date?
    public var location: String?
    /// One line on what was said, so the suggestion is checkable without the transcript.
    public var context: String?
    /// When the user put it in their calendar.
    public var addedAt: Date?
    /// Hidden by the user.
    public var dismissed: Bool

    public init(id: UUID = UUID(), title: String, start: EventDate, end: Date? = nil, location: String? = nil,
                context: String? = nil, addedAt: Date? = nil, dismissed: Bool = false) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.location = location
        self.context = context; self.addedAt = addedAt; self.dismissed = dismissed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Event"
        start = try c.decode(EventDate.self, forKey: .start)
        end = try? c.decodeIfPresent(Date.self, forKey: .end)
        location = try? c.decodeIfPresent(String.self, forKey: .location)
        context = try? c.decodeIfPresent(String.self, forKey: .context)
        addedAt = try? c.decodeIfPresent(Date.self, forKey: .addedAt)
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
    }

    public var isAllDay: Bool { !start.hasTime }
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
    /// Dates the summary found in the conversation, offered as calendar events.
    public var events: [MeetingEvent]
    public var speakerNames: [String: String]
    public var errorMessage: String?
    public var importedFileName: String?
    public var updatedAt: Date

    public init(id: UUID = UUID(), projectID: UUID, title: String, titleIsAuto: Bool = true,
                startedAt: Date = Date(), durationSeconds: Double = 0, status: MeetingStatus = .recorded,
                source: MeetingSource = .live, actionItems: [ActionItem] = [], events: [MeetingEvent] = [],
                speakerNames: [String: String] = [:], errorMessage: String? = nil, importedFileName: String? = nil,
                updatedAt: Date? = nil) {
        self.id = id; self.projectID = projectID; self.title = title; self.titleIsAuto = titleIsAuto
        self.startedAt = startedAt; self.durationSeconds = durationSeconds; self.status = status
        self.source = source; self.actionItems = actionItems; self.events = events; self.speakerNames = speakerNames
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
        events = (try? c.decodeIfPresent([MeetingEvent].self, forKey: .events)) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        importedFileName = try c.decodeIfPresent(String.self, forKey: .importedFileName)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? startedAt
    }

    public var openActionItems: [ActionItem] { actionItems.filter { !$0.done } }
    /// Suggested events the user hasn't hidden, soonest first.
    public var upcomingEvents: [MeetingEvent] { events.filter { !$0.dismissed }.sorted { $0.start.date < $1.start.date } }

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
        /// `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM` in the summarizing machine's zone; see `LocalDate.parse`.
        public var dueDate: String?

        enum CodingKeys: String, CodingKey { case owner, task, due; case dueDate = "due_date" }

        public init(owner: String? = nil, task: String, due: String? = nil, dueDate: String? = nil) {
            self.owner = owner; self.task = task; self.due = due; self.dueDate = dueDate
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            owner = try? c.decodeIfPresent(String.self, forKey: .owner)
            task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
            due = try? c.decodeIfPresent(String.self, forKey: .due)
            dueDate = try? c.decodeIfPresent(String.self, forKey: .dueDate)
        }
    }

    /// A dated happening the model spotted. Dates are local strings like `Item.dueDate`.
    public struct Event: Codable, Sendable {
        public var title: String
        public var start: String
        public var end: String?
        public var allDay: Bool
        public var location: String?
        public var context: String?

        enum CodingKeys: String, CodingKey { case title, start, end, location, context; case allDay = "all_day" }

        public init(title: String, start: String, end: String? = nil, allDay: Bool = false, location: String? = nil, context: String? = nil) {
            self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.context = context
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            start = try c.decodeIfPresent(String.self, forKey: .start) ?? ""
            end = try? c.decodeIfPresent(String.self, forKey: .end)
            allDay = (try? c.decodeIfPresent(Bool.self, forKey: .allDay)) ?? false
            location = try? c.decodeIfPresent(String.self, forKey: .location)
            context = try? c.decodeIfPresent(String.self, forKey: .context)
        }
    }

    public var title: String?
    public var summary: String
    public var decisions: [String]
    public var actionItems: [Item]
    public var openQuestions: [String]
    public var events: [Event]

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions, events
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    public init(title: String? = nil, summary: String, decisions: [String] = [], actionItems: [Item] = [],
                openQuestions: [String] = [], events: [Event] = []) {
        self.title = title; self.summary = summary; self.decisions = decisions
        self.actionItems = actionItems; self.openQuestions = openQuestions; self.events = events
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        decisions = (try? c.decodeIfPresent([String].self, forKey: .decisions)) ?? []
        actionItems = (try? c.decodeIfPresent([Item].self, forKey: .actionItems)) ?? []
        openQuestions = (try? c.decodeIfPresent([String].self, forKey: .openQuestions)) ?? []
        events = (try? c.decodeIfPresent([Event].self, forKey: .events)) ?? []
    }
}
