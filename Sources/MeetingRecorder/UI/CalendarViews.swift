import EventKit
import MeetingCore
import SwiftUI

// The pieces that turn a date the summary found into a calendar entry. Modeled on the data-detector popover in
// Mail: a small event card you can adjust, one button to add it, and "Show in Calendar" once it's in.

/// Calendar-app-style tile: month over day number.
struct DateTile: View {
    let date: Date
    var zone: TimeZone = .current

    var body: some View {
        var cal = Calendar.current
        cal.timeZone = zone
        let month = DateFormatter()
        month.timeZone = zone
        month.setLocalizedDateFormatFromTemplate("MMM")
        return VStack(spacing: 0) {
            Text(month.string(from: date).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(Color.red)
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 40, height: 40)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
    }
}

/// The popover. Edit the title/time/calendar, then Add. Access is requested when it opens, so the system prompt
/// appears at the moment the user is clearly trying to use their calendar.
struct AddToCalendarPopover: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var calendar = CalendarService.shared
    @Environment(\.dismiss) private var dismiss

    @State var draft: EventDraft
    /// Action items can also become reminders.
    var offerReminders = false
    /// Already in the calendar — open with "Show in Calendar" instead of "Add".
    var alreadyAdded = false
    let onAdded: (CalendarService.Destination) -> Void

    private enum Phase: Equatable {
        case editing, working
        case added(CalendarService.Destination, String)   // where, and the calendar's name
        case denied(CalendarService.Destination)
        case failed(String)
    }
    @State private var phase: Phase = .editing
    @State private var calendarID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            fields
            if let context = draft.context, !context.isEmpty {
                Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .task {
            if alreadyAdded { phase = .added(.calendar, "") }
            if calendar.eventAccess == .notDetermined { _ = await calendar.requestAccess(.calendar) }
            let preferred = calendar.calendar(withIdentifier: settings.calendarID) ?? calendar.defaultCalendar
            calendarID = preferred?.calendarIdentifier ?? ""
        }
        .onChange(of: draft.allDay) { _, allDay in
            if !allDay, draft.end <= draft.start { draft.end = draft.start.addingTimeInterval(3600) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            DateTile(date: draft.start)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Title", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.headline)
                Text(whenText).font(.callout).foregroundStyle(.secondary)
                if !draft.location.isEmpty {
                    Label(draft.location, systemImage: "mappin.and.ellipse")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var whenText: String {
        let d = EventDate(date: draft.start, hasTime: !draft.allDay)
        return Fmt.when(d, end: draft.allDay ? nil : draft.end)
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                label("All-day")
                Toggle("", isOn: $draft.allDay).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            GridRow {
                label("Starts")
                DatePicker("", selection: $draft.start, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
            }
            if !draft.allDay {
                GridRow {
                    label("Ends")
                    DatePicker("", selection: $draft.end, in: draft.start..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }
            GridRow {
                label("Location")
                TextField("None", text: $draft.location).textFieldStyle(.roundedBorder).controlSize(.small)
            }
            if calendar.canReadEvents, !calendar.calendars.isEmpty {
                GridRow {
                    label("Calendar")
                    Picker("", selection: $calendarID) {
                        ForEach(calendar.calendars, id: \.calendarIdentifier) { c in
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: c.color)).frame(width: 8, height: 8)
                                Text(c.title)
                            }
                            .tag(c.calendarIdentifier)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
        .font(.callout)
        .disabled(!editable)
    }

    private var editable: Bool {
        switch phase {
        case .editing, .failed: return true
        default: return false
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .editing, .failed:
            if case .failed(let why) = phase {
                Label(why, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if offerReminders {
                    Button("Add to Reminders") { add(.reminders) }.buttonStyle(.link).controlSize(.small)
                }
                Spacer()
                Button("Add to Calendar") { add(.calendar) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .working:
            HStack { ProgressView().controlSize(.small); Text("Adding…").foregroundStyle(.secondary); Spacer() }
        case .added(let where_, let name):
            HStack {
                Label(where_ == .calendar ? (name.isEmpty ? "In your calendar" : "Added to \(name)") : "Added to Reminders",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button(where_ == .calendar ? "Show in Calendar" : "Open Reminders") {
                    if where_ == .calendar { calendar.showInCalendar(draft) } else { CalendarService.openRemindersApp() }
                }
                .controlSize(.small)
                Button("Done") { dismiss() }.controlSize(.small).keyboardShortcut(.defaultAction)
            }
        case .denied(let where_):
            VStack(alignment: .leading, spacing: 8) {
                Text(where_ == .calendar
                     ? "Meeting Recorder doesn't have access to your calendar. Turn it on in System Settings, or hand the event to Calendar directly."
                     : "Meeting Recorder doesn't have access to Reminders. Turn it on in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings…") { CalendarService.openPrivacySettings(where_) }.controlSize(.small)
                    Spacer()
                    if where_ == .calendar {
                        Button("Open in Calendar") { CalendarService.openAsICS(draft); onAdded(.calendar); dismiss() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    } else {
                        Button("Back") { phase = .editing }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func add(_ to: CalendarService.Destination) {
        phase = .working
        Task {
            guard await calendar.requestAccess(to) else { phase = .denied(to); return }
            do {
                switch to {
                case .calendar:
                    let target = calendar.calendar(withIdentifier: calendarID)
                    let landed = try calendar.addEvent(draft, to: target)
                    if let landed { settings.calendarID = landed.calendarIdentifier }
                    phase = .added(.calendar, landed?.title ?? "")
                case .reminders:
                    try calendar.addReminder(draft)
                    phase = .added(.reminders, "")
                }
                onAdded(to)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Action items

/// The due-date chip on an action item. Click for the popover; a chevron appears on hover the way Mail's data
/// detectors do. Shows a check once the item is in the calendar.
struct DueDateChip: View {
    let item: ActionItem
    let meeting: Meeting
    let update: (ActionItem) -> Void
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 3) {
                Image(systemName: item.calendarAddedAt != nil ? "calendar.badge.checkmark" : "calendar")
                Text(item.dueLabel ?? (item.calendarAddedAt != nil ? "In Calendar" : "Add to Calendar"))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(hovering || showing ? 1 : 0)
            }
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering || showing ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AddToCalendarPopover(draft: EventDraft(item: item, meeting: meeting), offerReminders: true,
                                 alreadyAdded: item.calendarAddedAt != nil) { _ in
                var i = item
                i.calendarAddedAt = Date()
                update(i)
            }
        }
    }

    private var help: String {
        var parts: [String] = []
        if let due = item.due, !due.isEmpty, item.dueDate != nil { parts.append("“\(due)” in the meeting") }
        parts.append(item.calendarAddedAt != nil ? "In your calendar — click to show it" : "Add to Calendar or Reminders")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Suggested events

/// The "Upcoming" block at the top of the summary: one card per date the summary found.
struct UpcomingEventsView: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting

    var body: some View {
        let events = meeting.upcomingEvents
        let hidden = meeting.events.count - events.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(MeetingDocuments.upcomingHeading, systemImage: "calendar").font(.headline)
                Text(events.isEmpty ? "" : "found in this meeting").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if hidden > 0 {
                    Button(hidden == 1 ? "1 hidden" : "\(hidden) hidden") { restoreHidden() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .help("Show the events you hid")
                }
            }
            ForEach(events) { event in
                EventCard(event: event, meeting: meeting) { updated in save(updated) }
            }
        }
    }

    private func save(_ event: MeetingEvent) {
        guard var m = store.meeting(meeting.id), let i = m.events.firstIndex(where: { $0.id == event.id }) else { return }
        m.events[i] = event
        store.update(m)
    }

    private func restoreHidden() {
        guard var m = store.meeting(meeting.id) else { return }
        for i in m.events.indices { m.events[i].dismissed = false }
        store.update(m)
    }
}

struct EventCard: View {
    let event: MeetingEvent
    let meeting: Meeting
    let update: (MeetingEvent) -> Void
    @State private var showing = false
    @State private var hovering = false

    private var added: Bool { event.addedAt != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DateTile(date: event.start.date, zone: event.isAllDay ? event.start.tz : .current)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 4) {
                    Text(Fmt.when(event.start, end: event.end))
                    if let location = event.location, !location.isEmpty {
                        Text("·")
                        Label(location, systemImage: "mappin.and.ellipse").lineLimit(1)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                if let context = event.context, !context.isEmpty {
                    Text(context).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button { showing = true } label: {
                if added {
                    Label("Added", systemImage: "checkmark").foregroundStyle(.green)
                } else {
                    Label("Add", systemImage: "plus")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(added ? "In your calendar — click to show it" : "Add to your calendar")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AddToCalendarPopover(draft: EventDraft(event: event, meeting: meeting), alreadyAdded: added) { _ in
                    var e = event
                    e.addedAt = Date()
                    update(e)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hovering ? Color.secondary.opacity(0.4) : Color.secondary.opacity(0.2)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(added ? "Show in Calendar" : "Add to Calendar…") { showing = true }
            Divider()
            Button("Hide") { var e = event; e.dismissed = true; update(e) }
        }
    }
}
