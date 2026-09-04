import Foundation
import MeetingCore

/// The project-level material the summarizer reads and writes: the user's own CONTEXT.md, the note the model
/// keeps for itself in LEARNED.md, and the action items that are still open across the project's meetings.
extension Store {
    /// What the model has worked out about this project on its own. Separate from the user's CONTEXT.md on
    /// purpose — the model rewrites this file wholesale and must never touch what the user wrote.
    func learnedContext(_ id: UUID) -> String {
        guard let dir = folder(forProject: id) else { return "" }
        return (try? String(contentsOf: dir.appendingPathComponent(Store.learnedFileName), encoding: .utf8)) ?? ""
    }

    /// Replace the learned note, keeping the version it replaces so one bad rewrite is always undoable.
    func setLearnedContext(_ id: UUID, _ text: String, note: String? = nil) {
        guard let dir = folder(forProject: id) else { return }
        let url = dir.appendingPathComponent(Store.learnedFileName)
        if let current = try? String(contentsOf: url, encoding: .utf8), current != text {
            try? current.write(to: dir.appendingPathComponent(Store.learnedBackupFileName), atomically: true, encoding: .utf8)
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        if let note, !note.isEmpty {
            try? note.write(to: dir.appendingPathComponent(Store.learnedNoteFileName), atomically: true, encoding: .utf8)
        }
        if let p = project(id) { onChange?(.project(p)) }
        objectWillChange.send()
    }

    /// The version `setLearnedContext` displaced, if there is one.
    func previousLearnedContext(_ id: UUID) -> String? {
        guard let dir = folder(forProject: id) else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(Store.learnedBackupFileName), encoding: .utf8)
    }

    /// One line on what the last rewrite changed, for the context editor.
    func learnedContextNote(_ id: UUID) -> String? {
        guard let dir = folder(forProject: id),
              let note = try? String(contentsOf: dir.appendingPathComponent(Store.learnedNoteFileName), encoding: .utf8),
              !note.isEmpty else { return nil }
        return note
    }

    /// Put the previous learned note back. The version being undone becomes the new backup, so this toggles.
    @discardableResult
    func revertLearnedContext(_ id: UUID) -> Bool {
        guard let previous = previousLearnedContext(id) else { return false }
        setLearnedContext(id, previous, note: "Reverted to the previous version.")
        return true
    }

    /// Both context blocks, as the summarizer sees them.
    func contexts(_ id: UUID) -> (user: String, learned: String) {
        (projectContext(id), learnedContext(id))
    }

    /// Everything still open in the project apart from this meeting's own items, numbered for the prompt.
    func openProjectItems(for meeting: Meeting) -> [OpenProjectItem] {
        ActionItems.openProjectItems(in: meetings(in: meeting.projectID), excluding: meeting.id)
    }

    /// Look up the live copy of an item by id, across the project's meetings.
    func itemsByID(in projectID: UUID) -> [UUID: ActionItem] {
        var map: [UUID: ActionItem] = [:]
        for m in meetings(in: projectID) {
            for item in m.actionItems { map[item.id] = item }
        }
        return map
    }

    /// Write items that a later meeting changed back to the meetings they belong to.
    func applyCarriedEdits(_ edits: [ActionItems.CarriedItem]) {
        let byMeeting = Dictionary(grouping: edits, by: \.meetingID)
        for (meetingID, changes) in byMeeting {
            guard var m = meeting(meetingID) else { continue }
            var touched = false
            for change in changes {
                guard let i = m.actionItems.firstIndex(where: { $0.id == change.item.id }) else { continue }
                m.actionItems[i] = change.item
                touched = true
            }
            if touched { update(m) }
        }
    }

    static let learnedFileName = "LEARNED.md"
    /// Hidden so the project folder stays readable in Finder.
    static let learnedBackupFileName = ".LEARNED.previous.md"
    static let learnedNoteFileName = ".LEARNED.note.txt"
}
