import AppKit
import EventKit
import Foundation
import MeetingCore

/// What gets written to Calendar or Reminders — a suggested event or an action item, after the user has looked
/// it over in the popover.
struct EventDraft {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String
    /// The line from the conversation that produced this; shown in the popover, kept in the event's notes.
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
            // No resolved deadline: tomorrow, whole day — the user picks in the popover.
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

/// EventKit, kept out of the views. Access is asked for lazily — the first time the user opens an
/// "Add to Calendar" popover — and never again after that; the answer lives in System Settings.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    enum Destination { case calendar, reminders }

    let store = EKEventStore()
    @Published private(set) var eventAccess = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminderAccess = EKEventStore.authorizationStatus(for: .reminder)

    var canWriteEvents: Bool { eventAccess == .fullAccess || eventAccess == .writeOnly }
    var canReadEvents: Bool { eventAccess == .fullAccess }
    var canWriteReminders: Bool { reminderAccess == .fullAccess }

    func requestAccess(_ to: Destination) async -> Bool {
        switch to {
        case .calendar:
            if canWriteEvents { return true }
            let ok = (try? await store.requestFullAccessToEvents()) ?? false
            eventAccess = EKEventStore.authorizationStatus(for: .event)
            return ok
        case .reminders:
            if canWriteReminders { return true }
            let ok = (try? await store.requestFullAccessToReminders()) ?? false
            reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
            return ok
        }
    }

    /// Calendars the user can put events in, the way Calendar lists them.
    var calendars: [EKCalendar] {
        guard canReadEvents else { return [] }
        return store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    func calendar(withIdentifier id: String) -> EKCalendar? {
        guard !id.isEmpty else { return nil }
        return store.calendar(withIdentifier: id)
    }

    var defaultCalendar: EKCalendar? { store.defaultCalendarForNewEvents }

    /// Saves the event; returns the calendar it landed in.
    @discardableResult
    func addEvent(_ draft: EventDraft, to calendar: EKCalendar?) throws -> EKCalendar? {
        let d = draft.normalized
        let event = EKEvent(eventStore: store)
        event.title = d.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Event" : d.title
        event.isAllDay = d.allDay
        event.startDate = d.start
        event.endDate = d.end
        event.location = d.location.isEmpty ? nil : d.location
        event.notes = d.notes
        event.calendar = calendar ?? store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return event.calendar
    }

    func addReminder(_ draft: EventDraft) throws {
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

    // MARK: - Showing what was added

    /// Open the event in Calendar. We don't keep EventKit identifiers (they're per device); the event is looked up
    /// by title around its time, which also finds it on another Mac sharing the same calendars.
    func showInCalendar(_ draft: EventDraft) {
        let d = draft.normalized
        if canReadEvents {
            let window = store.predicateForEvents(withStart: d.start.addingTimeInterval(-86_400), end: d.end.addingTimeInterval(86_400), calendars: nil)
            let match = store.events(matching: window)
                .filter { $0.title.caseInsensitiveCompare(d.title) == .orderedSame }
                .min { abs($0.startDate.timeIntervalSince(d.start)) < abs($1.startDate.timeIntervalSince(d.start)) }
            if let id = match?.eventIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "ical://ekevent/\(id)"), NSWorkspace.shared.open(url) {
                return
            }
        }
        Self.openCalendarApp()
    }

    static func openCalendarApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    static func openRemindersApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }

    static func openPrivacySettings(_ for: Destination) {
        let pane = `for` == .calendar ? "Privacy_Calendars" : "Privacy_Reminders"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// Without calendar access: hand Calendar an .ics and let it show its own "Add to calendar" sheet.
    static func openAsICS(_ draft: EventDraft) {
        let d = draft.normalized
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(Fmt.sanitizeFilename(d.title)).ics")
        do {
            try ICS.render(d).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            Log.pipeline.error("couldn't write .ics: \(error.localizedDescription)")
        }
    }
}

/// Minimal iCalendar writer (RFC 5545) — one VEVENT.
enum ICS {
    static func render(_ d: EventDraft) -> String {
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyyMMdd"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Meeting Recorder//EN", "BEGIN:VEVENT",
                     "UID:\(UUID().uuidString)@meetingrecorder", "DTSTAMP:\(utc.string(from: Date()))"]
        if d.allDay {
            let next = Calendar.current.date(byAdding: .day, value: 1, to: d.start) ?? d.start
            lines += ["DTSTART;VALUE=DATE:\(day.string(from: d.start))", "DTEND;VALUE=DATE:\(day.string(from: next))"]
        } else {
            lines += ["DTSTART:\(utc.string(from: d.start))", "DTEND:\(utc.string(from: d.end))"]
        }
        lines.append("SUMMARY:\(escape(d.title))")
        if !d.location.isEmpty { lines.append("LOCATION:\(escape(d.location))") }
        lines.append("DESCRIPTION:\(escape(d.notes))")
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Lines longer than 75 octets continue on the next line after a space.
    private static func fold(_ line: String) -> String {
        var out = ""
        var current = ""
        for ch in line {
            if (current + String(ch)).utf8.count > 74 { out += current + "\r\n "; current = "" }
            current.append(ch)
        }
        return out + current
    }
}
