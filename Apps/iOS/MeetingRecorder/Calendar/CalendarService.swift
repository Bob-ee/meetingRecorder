import EventKit
import Foundation
import MeetingCore

/// What gets written to Calendar or Reminders — a suggested event or an action item.
struct EventDraft {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String
    /// The line from the conversation that produced this; kept in the event's notes.
    var context: String?
    let meeting: Meeting

    init(event: MeetingEvent, meeting: Meeting) {
        self.meeting = meeting
        title = event.title
        allDay = event.isAllDay
        start = allDay ? event.start.date(in: .current) : event.start.date
        end = event.end ?? start.addingTimeInterval(allDay ? 0 : 3600)
        location = event.location ?? ""
        context = event.context
    }

    init(item: ActionItem, meeting: Meeting) {
        self.meeting = meeting
        title = item.task
        if let due = item.dueDate {
            allDay = !due.hasTime
            start = allDay ? due.date(in: .current) : due.date
        } else {
            // No resolved deadline: tomorrow, whole day — the user picks in the editor.
            allDay = true
            start = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        }
        end = allDay ? start : start.addingTimeInterval(3600)
        location = ""
        var lines: [String] = []
        if let owner = item.owner, !owner.isEmpty { lines.append("Owner: \(owner)") }
        if let due = item.due, !due.isEmpty { lines.append("Due: \(due)") }
        context = lines.isEmpty ? nil : lines.joined(separator: " · ")
    }

    var notes: String {
        var out: [String] = []
        if let context, !context.isEmpty { out.append(context) }
        out.append("From “\(meeting.title)” — \(Fmt.dateTime.string(from: meeting.startedAt)) (Meeting Recorder)")
        return out.joined(separator: "\n\n")
    }

    /// `end` never before `start`; whole days end when they start.
    var normalized: EventDraft {
        var d = self
        if d.allDay { d.end = d.start } else if d.end <= d.start { d.end = d.start.addingTimeInterval(3600) }
        return d
    }
}

/// EventKit, kept out of the views. Events go through the system's own editor (see `EventEditor`), which needs
/// no permission; only Reminders asks for access, and only when the user first sends something there.
@MainActor
final class CalendarService {
    static let shared = CalendarService()

    let store = EKEventStore()

    /// The draft as an unsaved event, for the system editor to show.
    func event(from draft: EventDraft) -> EKEvent {
        let d = draft.normalized
        let event = EKEvent(eventStore: store)
        event.title = d.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Event" : d.title
        event.isAllDay = d.allDay
        event.startDate = d.start
        event.endDate = d.end
        event.location = d.location.isEmpty ? nil : d.location
        event.notes = d.notes
        return event
    }

    func addReminder(_ draft: EventDraft) async throws {
        guard (try? await store.requestFullAccessToReminders()) == true else { throw CalendarError.remindersDenied }
        let d = draft.normalized
        let reminder = EKReminder(eventStore: store)
        reminder.title = d.title
        reminder.notes = d.notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        let cal = Calendar.current
        if d.allDay {
            reminder.dueDateComponents = cal.dateComponents([.year, .month, .day], from: d.start)
        } else {
            reminder.dueDateComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d.start)
            reminder.addAlarm(EKAlarm(absoluteDate: d.start))
        }
        try store.save(reminder, commit: true)
    }
}

enum CalendarError: LocalizedError {
    case remindersDenied
    var errorDescription: String? {
        "Meeting Recorder doesn't have access to Reminders. Turn it on in Settings → Privacy & Security → Reminders."
    }
}
