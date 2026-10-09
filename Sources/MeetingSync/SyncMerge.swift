import Foundation
import MeetingCore

/// How two copies of the same thing are reconciled, and how a device works out what it has to send.
///
/// A device keeps, next to each project and meeting, the copy the hub last gave it — the *base*. That makes
/// both questions simple. What did I change? Whatever differs from the base. What do I do with the hub's newer
/// copy? Take it, except where I changed something — there, mine stands until the hub has it.
///
/// Only what a person edits takes part: titles, notes, speaker names, which project a meeting is in, an action
/// item's wording and state, whether an event was added or dismissed. Everything else — status, the transcript,
/// advice written for an item — is the hub's to say, and always comes from its copy.
public enum SyncMerge {
    /// `local` if this device changed the value since `base`, otherwise whatever the hub has now.
    static func pick<T: Equatable>(_ base: T, _ local: T, _ remote: T) -> T {
        local == base ? remote : local
    }

    public static func project(base: ProjectDetail, local: ProjectDetail, remote: ProjectDetail) -> ProjectDetail {
        var out = remote
        out.project.name = pick(base.project.name, local.project.name, remote.project.name)
        out.context = pick(base.context, local.context, remote.context)
        out.learnedContext = pick(base.learnedContext, local.learnedContext, remote.learnedContext)
        return out
    }

    public static func meeting(base: MeetingRecord, local: MeetingRecord, remote: MeetingRecord) -> MeetingRecord {
        var out = remote
        // A title and whether it was typed by a person travel together.
        if local.meeting.title != base.meeting.title || local.meeting.titleIsAuto != base.meeting.titleIsAuto {
            out.meeting.title = local.meeting.title
            out.meeting.titleIsAuto = local.meeting.titleIsAuto
        }
        out.meeting.projectID = pick(base.meeting.projectID, local.meeting.projectID, remote.meeting.projectID)
        out.notes = pick(base.notes, local.notes, remote.notes)
        out.meeting.speakerNames = speakerNames(base: base.meeting.speakerNames, local: local.meeting.speakerNames,
                                                remote: remote.meeting.speakerNames)
        out.meeting.actionItems = actionItems(base: base.meeting.actionItems, local: local.meeting.actionItems,
                                              remote: remote.meeting.actionItems)
        out.meeting.events = events(base: base.meeting.events, local: local.meeting.events, remote: remote.meeting.events)
        return out
    }

    /// Each speaker's name is its own value, so renaming one speaker here and another elsewhere keeps both.
    static func speakerNames(base: [String: String], local: [String: String], remote: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for speaker in Set(base.keys).union(local.keys).union(remote.keys) {
            out[speaker] = pick(base[speaker], local[speaker], remote[speaker])
        }
        return out
    }

    /// The hub's list in the hub's order, with this device's unsent edits laid over it: items it removed stay
    /// out, items it added go on the end. An item the hub no longer has is gone, even if it was edited here.
    static func actionItems(base: [ActionItem], local: [ActionItem], remote: [ActionItem]) -> [ActionItem] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteIDs = Set(remote.map(\.id))

        var out: [ActionItem] = remote.compactMap { theirs in
            guard let mine = localByID[theirs.id] else {
                // Not here: either it's new from the hub, or this device removed it and hasn't said so yet.
                return baseByID[theirs.id] == nil ? theirs : nil
            }
            // Here but not in the base: this device added it and the reply was lost. Its copy is the newer one.
            guard let was = baseByID[theirs.id] else { return theirs.replacingEditable(with: mine) }
            return was.editable == mine.editable ? theirs : theirs.replacingEditable(with: mine)
        }
        out += local.filter { !remoteIDs.contains($0.id) && baseByID[$0.id] == nil }
        return out
    }

    /// Events are the hub's; all a device changes is whether one was put in a calendar or dismissed.
    static func events(base: [MeetingEvent], local: [MeetingEvent], remote: [MeetingEvent]) -> [MeetingEvent] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return remote.map { theirs in
            guard let was = baseByID[theirs.id], let mine = localByID[theirs.id] else { return theirs }
            var event = theirs
            event.addedAt = pick(was.addedAt, mine.addedAt, theirs.addedAt)
            event.dismissed = pick(was.dismissed, mine.dismissed, theirs.dismissed)
            return event
        }
    }

    /// Whether two copies say the same thing, leaving out what differs for bookkeeping reasons alone.
    public static func same(_ a: MeetingRecord, _ b: MeetingRecord) -> Bool {
        var a = a, b = b
        a.meeting.updatedAt = b.meeting.updatedAt
        a.contentTag = b.contentTag
        return a == b
    }

    public static func same(_ a: ProjectDetail, _ b: ProjectDetail) -> Bool {
        a.project.id == b.project.id && a.project.name == b.project.name
            && a.context == b.context && a.learnedContext == b.learnedContext
    }
}

// MARK: - What a device has to send

public extension MeetingEdit {
    /// The changes that turn `base` — the hub's copy as this device last saw it — into `local`.
    init(from base: MeetingRecord, to local: MeetingRecord) {
        self.init()
        if local.meeting.title != base.meeting.title { title = local.meeting.title }
        if title != nil || local.meeting.titleIsAuto != base.meeting.titleIsAuto { titleIsAuto = local.meeting.titleIsAuto }
        if local.meeting.projectID != base.meeting.projectID { projectID = local.meeting.projectID }
        if local.notes != base.notes { notes = local.notes }
        let renamed = Set(base.meeting.speakerNames.keys).union(local.meeting.speakerNames.keys)
            .filter { base.meeting.speakerNames[$0] != local.meeting.speakerNames[$0] }
        if !renamed.isEmpty {
            speakerNames = Dictionary(uniqueKeysWithValues: renamed.map { ($0, local.meeting.speakerNames[$0] ?? "") })
        }

        let baseItems = Dictionary(base.meeting.actionItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localIDs = Set(local.meeting.actionItems.map(\.id))
        for item in local.meeting.actionItems {
            guard let was = baseItems[item.id] else { addedItems.append(item); continue }
            if was.editable != item.editable { changedItems.append(item) }
        }
        removedItems = base.meeting.actionItems.map(\.id).filter { !localIDs.contains($0) }

        let baseEvents = Dictionary(base.meeting.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        changedEvents = local.meeting.events.filter { event in
            guard let was = baseEvents[event.id] else { return false }
            return was.addedAt != event.addedAt || was.dismissed != event.dismissed
        }
    }
}

public extension PatchProjectRequest {
    /// The changes that turn `base` into `local`, or nil when there are none.
    init?(from base: ProjectDetail, to local: ProjectDetail) {
        self.init(name: local.project.name == base.project.name ? nil : local.project.name,
                  context: local.context == base.context ? nil : local.context,
                  learnedContext: local.learnedContext == base.learnedContext ? nil : local.learnedContext)
        if name == nil, context == nil, learnedContext == nil { return nil }
    }
}

extension ActionItem {
    /// The part of an action item a person edits — and so the part that is merged and sent.
    struct Editable: Equatable {
        var task: String
        var owner: String?
        var due: String?
        var dueDate: EventDate?
        var done: Bool
        var calendarAddedAt: Date?
    }

    var editable: Editable {
        Editable(task: task, owner: owner, due: due, dueDate: dueDate, done: done, calendarAddedAt: calendarAddedAt)
    }

    /// This item with its editable part taken from `other`.
    func replacingEditable(with other: ActionItem) -> ActionItem {
        var item = self
        item.task = other.task; item.owner = other.owner; item.due = other.due
        item.dueDate = other.dueDate; item.done = other.done; item.calendarAddedAt = other.calendarAddedAt
        return item
    }
}
