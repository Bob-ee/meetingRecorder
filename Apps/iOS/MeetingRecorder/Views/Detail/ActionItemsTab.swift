import MeetingCore
import SwiftUI

struct ActionItemsTab: View {
    @EnvironmentObject var library: Library
    let meeting: Meeting
    @State private var newTask = ""

    var body: some View {
        let carried = carriedOver
        List {
            Section {
                ForEach(meeting.actionItems) { item in
                    ActionItemRow(item: item, meeting: meeting)
                }
                HStack {
                    TextField("Add an action item…", text: $newTask)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                let open = meeting.openActionItems.count
                Text(meeting.actionItems.isEmpty ? "No action items yet" : "\(open) open · \(meeting.actionItems.count - open) done")
            }
            if !carried.isEmpty {
                Section("Still open from earlier meetings") {
                    ForEach(carried, id: \.item.id) { row in
                        ActionItemRow(item: row.item, meeting: row.meeting, showMeeting: true)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// Items this meeting revisited but that belong to the meeting that first raised them — so restating a task
    /// week after week doesn't produce a new copy of it every time.
    private var carriedOver: [(item: ActionItem, meeting: Meeting)] {
        library.meetings(in: meeting.projectID)
            .filter { $0.id != meeting.id }
            .flatMap { m in m.openActionItems.filter { $0.lastDiscussedMeetingID == meeting.id }.map { (item: $0, meeting: m) } }
    }

    private func add() {
        library.addItem(newTask, to: meeting.id)
        newTask = ""
    }
}

/// One action item. `meeting` is the meeting the item belongs to, which is where its edits go — not
/// necessarily the meeting on screen.
struct ActionItemRow: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    let item: ActionItem
    let meeting: Meeting
    /// Show which meeting the item came from. On for lists that aren't already grouped by meeting.
    var showMeeting = false
    /// Set where the row can lead to its meeting.
    var openMeeting: (() -> Void)?
    @State private var expanded = false
    @State private var addingToCalendar = false

    private var advising: Bool { app.advising.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    var i = item; i.done.toggle(); library.update(i, in: meeting.id)
                } label: {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.done ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.task).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                    caption
                }
                Spacer(minLength: 4)
                guidanceButton
            }
            if expanded, let guidance = item.guidance { GuidancePanel(item: item, text: guidance, meetingID: meeting.id) }
            if let error = app.adviceErrors[item.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { library.removeItem(item.id, from: meeting.id) }
        }
        .contextMenu {
            Button(item.guidance == nil ? "Suggest How to Handle This" : "Suggest How to Handle This Again",
                   systemImage: "wand.and.stars", action: requestGuidance)
                .disabled(advising)
            Button("Add to Calendar…", systemImage: "calendar.badge.plus") { addingToCalendar = true }
            Button("Add to Reminders", systemImage: "list.bullet", action: addReminder)
            if let openMeeting { Button("Open Meeting", systemImage: "text.bubble", action: openMeeting) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { library.removeItem(item.id, from: meeting.id) }
        }
        .sheet(isPresented: $addingToCalendar) {
            EventEditor(draft: EventDraft(item: item, meeting: meeting), onAdded: markAdded)
                .ignoresSafeArea()
        }
    }

    private var caption: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { captionParts }
            VStack(alignment: .leading, spacing: 2) { captionParts }
        }
        .labelStyle(.caption)
        .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var captionParts: some View {
        if let owner = item.owner, !owner.isEmpty { Label(owner, systemImage: "person") }
        if item.dueLabel != nil || item.calendarAddedAt != nil {
            Button { addingToCalendar = true } label: {
                Label(item.dueLabel ?? "In Calendar",
                      systemImage: item.calendarAddedAt != nil ? "calendar.badge.checkmark" : "calendar")
            }
            .buttonStyle(.plain)
        }
        if showMeeting {
            Button { openMeeting?() } label: {
                Label("\(meeting.title) · \(Fmt.dateOnly.string(from: meeting.startedAt))", systemImage: "text.bubble")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(openMeeting == nil)
        }
        if let revisited = item.lastDiscussedMeetingID, revisited != meeting.id, library.meeting(revisited) != nil {
            Text("still open")
        }
        if item.isManual { Text("added by you").italic() }
    }

    @ViewBuilder
    private var guidanceButton: some View {
        if advising {
            ProgressView().controlSize(.small)
        } else if item.guidance != nil {
            Button { expanded.toggle() } label: { Image(systemName: expanded ? "lightbulb.fill" : "lightbulb") }
                .buttonStyle(.borderless)
        } else {
            Button(action: requestGuidance) { Image(systemName: "wand.and.stars") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    private func requestGuidance() {
        expanded = true
        app.requestGuidance(for: item.id, in: meeting.id)
    }

    private func markAdded() {
        var i = item
        i.calendarAddedAt = Date()
        library.update(i, in: meeting.id)
    }

    private func addReminder() {
        Task {
            do {
                try await CalendarService.shared.addReminder(EventDraft(item: item, meeting: meeting))
                markAdded()
            } catch {
                app.alert = error.localizedDescription
            }
        }
    }
}

/// The model's answer to "how would you handle this", shown under the item that asked for it.
struct GuidancePanel: View {
    @EnvironmentObject var app: AppModel
    let item: ActionItem
    let text: String
    let meetingID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Suggested approach", systemImage: "lightbulb").font(.caption.weight(.semibold))
                if let at = item.guidanceAt {
                    Text(Fmt.dateOnly.string(from: at)).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Regenerate") { app.requestGuidance(for: item.id, in: meetingID) }
                    .disabled(app.advising.contains(item.id))
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            MarkdownView(markdown: text)
                .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        .padding(.leading, 34)
    }
}
