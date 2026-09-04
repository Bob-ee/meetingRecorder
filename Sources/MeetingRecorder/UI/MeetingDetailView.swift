import MeetingCore
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    let meetingID: UUID

    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript", actions = "Action Items", notes = "Notes" }
    @State private var tab: Tab = .summary
    @State private var title = ""

    var body: some View {
        if let meeting = store.meeting(meetingID) {
            VStack(alignment: .leading, spacing: 0) {
                header(meeting)
                Divider()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16).padding(.vertical, 10)

                Group {
                    switch tab {
                    case .summary: SummaryTab(meeting: meeting)
                    case .transcript: TranscriptTab(meeting: meeting)
                    case .actions: ActionItemsTab(meeting: meeting)
                    case .notes: NotesTab(meeting: meeting)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { title = meeting.title }
            .onChange(of: meetingID) { _, _ in title = store.meeting(meetingID)?.title ?? ""; tab = .summary }
            .onChange(of: meeting.title) { _, new in if title != new { title = new } }
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Meeting title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .onSubmit { commitTitle(meeting) }
            HStack(spacing: 10) {
                Text(Fmt.dateTime.string(from: meeting.startedAt))
                if meeting.durationSeconds > 0 { Text("·"); Text(Fmt.duration(meeting.durationSeconds)) }
                if let p = store.project(meeting.projectID) { Text("·"); Label(p.name, systemImage: "folder") }
                StatusChip(status: meeting.status)
                if let progress = pipeline.progress[meeting.id] { Text(progress).foregroundStyle(.tertiary) }
                Spacer()
                Menu {
                    Button("Copy Everything") { Clipboard.copy(store.exportForClaude(meeting)) }
                    Divider()
                    Button("Re-summarize") { pipeline.run(meeting, transcribe: false, summarize: true) }
                        .disabled(!store.hasTranscript(meeting))
                    Button("Re-transcribe & Summarize") { pipeline.run(meeting, transcribe: true, summarize: true) }
                    Divider()
                    Button("Show in Finder") { store.revealInFinder(meeting) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let err = meeting.errorMessage, meeting.status == .failed {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).textSelection(.enabled)
                    Spacer()
                    Button("Retry") {
                        pipeline.run(meeting, transcribe: !store.hasTranscript(meeting), summarize: true)
                    }
                }
                .font(.callout)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.1)))
            }
        }
        .padding(16)
    }

    private func commitTitle(_ meeting: Meeting) {
        var m = meeting
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != m.title else { return }
        m.title = t
        m.titleIsAuto = false
        store.update(m)
    }
}

/// "Copy …" button with a brief "Copied" confirmation. ⇧⌘C triggers the one on the visible tab.
struct CopyButton: View {
    let title: String
    var disabled = false
    let make: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(make())
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(disabled)
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .help("\(title) — pastes formatted into Mail, Gmail, Docs, Slack; plain Markdown elsewhere (⇧⌘C)")
    }
}

/// Thin bar at the top of each tab: a hint on the left, the tab's copy button on the right.
struct TabBar<Leading: View>: View {
    let leading: Leading
    let copy: CopyButton

    init(copy: CopyButton, @ViewBuilder leading: () -> Leading) {
        self.copy = copy
        self.leading = leading()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                leading
                Spacer()
                copy
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
        }
    }
}

// MARK: - Summary

struct SummaryTab: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    let meeting: Meeting

    var body: some View {
        if let md = store.summaryMarkdown(for: meeting) {
            let export = store.summaryExport(for: meeting) ?? md
            VStack(spacing: 0) {
                TabBar(copy: CopyButton(title: "Copy summary") { export }) {
                    Text("Overview, decisions, action items and open questions").foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Dates the summary found, as one-click calendar events; the same list is in the
                        // Markdown as "## Upcoming", so leave that section out of what's rendered below.
                        if !meeting.events.isEmpty { UpcomingEventsView(meeting: meeting) }
                        MarkdownView(markdown: MeetingDocuments.removingSection(export, titled: MeetingDocuments.upcomingHeading))
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            VStack(spacing: 10) {
                if meeting.status.isBusy {
                    ProgressView()
                    Text(pipeline.progress[meeting.id] ?? meeting.status.label).foregroundStyle(.secondary)
                } else if meeting.status == .recording {
                    Text("Recording in progress…").foregroundStyle(.secondary)
                } else {
                    Text("No summary yet").foregroundStyle(.secondary)
                    Button("Summarize now") { pipeline.run(meeting, transcribe: !store.hasTranscript(meeting), summarize: true) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Transcript

struct TranscriptTab: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    @State private var renaming: String?
    @State private var renameText = ""

    private var segments: [TranscriptSegment] { store.transcript(for: meeting) }

    var body: some View {
        let segs = segments
        if segs.isEmpty {
            Text(meeting.status.isBusy ? "Transcribing…" : "No transcript yet")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    let speakers = Array(Set(segs.map { $0.speaker })).sorted()
                    Text("Speakers:").foregroundStyle(.secondary)
                    ForEach(speakers, id: \.self) { s in
                        Button {
                            renameText = meeting.speakerNames[s] ?? ""
                            renaming = s
                        } label: {
                            Text(meeting.displayName(forSpeaker: s))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(SpeakerColor.color(for: s).opacity(0.15)))
                                .foregroundStyle(SpeakerColor.color(for: s))
                        }
                        .buttonStyle(.plain)
                        .help("Rename this speaker")
                    }
                    Spacer()
                    CopyButton(title: "Copy transcript") { store.transcriptMarkdown(segs, meeting: meeting) }
                }
                .font(.callout)
                .padding(.horizontal, 16).padding(.bottom, 8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(segs) { seg in
                            HStack(alignment: .top, spacing: 10) {
                                Text(Fmt.timestamp(seg.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 60, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meeting.displayName(forSpeaker: seg.speaker))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(SpeakerColor.color(for: seg.speaker))
                                    Text(seg.text).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .alert("Rename \(renaming ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let s = renaming { store.renameSpeaker(s, to: renameText, in: meeting.id) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Leave empty to restore the default label.")
            }
        }
    }
}

enum SpeakerColor {
    static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .brown]
    static func color(for speaker: String) -> Color {
        if speaker == "You" || !speaker.hasPrefix("Speaker ") { return .accentColor }
        let n = Int(speaker.dropFirst("Speaker ".count)) ?? 0
        return palette[(max(n, 1) - 1) % palette.count]
    }
}

// MARK: - Action items

struct ActionItemsTab: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    @State private var newTask = ""

    var body: some View {
        VStack(spacing: 0) {
            TabBar(copy: CopyButton(title: "Copy action items", disabled: meeting.actionItems.isEmpty) { store.actionItemsMarkdown(meeting) }) {
                let open = meeting.openActionItems.count
                let done = meeting.actionItems.count - open
                Text(meeting.actionItems.isEmpty ? "No action items yet" : "\(open) open · \(done) done").foregroundStyle(.secondary)
            }
            let carried = carriedOver
            if meeting.actionItems.isEmpty && carried.isEmpty {
                Text("No action items").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(meeting.actionItems) { item in
                        own(item)
                    }
                    if !carried.isEmpty {
                        Section("Still open from earlier meetings") {
                            ForEach(carried, id: \.item.id) { row in
                                elsewhere(row)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                TextField("Add an action item…", text: $newTask)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    /// Items this meeting revisited but that belong to the meeting that first raised them — so restating a task
    /// week after week doesn't produce a new copy of it every time.
    private var carriedOver: [(item: ActionItem, meeting: Meeting)] {
        store.meetings(in: meeting.projectID)
            .filter { $0.id != meeting.id }
            .flatMap { m in m.openActionItems.filter { $0.lastDiscussedMeetingID == meeting.id }.map { (item: $0, meeting: m) } }
            .sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    private func own(_ item: ActionItem) -> some View {
        ActionItemRow(item: item, meeting: meeting) { updated in
            var m = meeting
            if let i = m.actionItems.firstIndex(where: { $0.id == item.id }) { m.actionItems[i] = updated }
            store.update(m)
        } delete: {
            var m = meeting
            m.actionItems.removeAll { $0.id == item.id }
            store.update(m)
        }
    }

    /// An item this meeting brought up again; edits go back to the meeting that owns it.
    private func elsewhere(_ row: (item: ActionItem, meeting: Meeting)) -> some View {
        let owner = row.meeting
        let item = row.item
        return ActionItemRow(item: item, meeting: owner, showMeeting: true) { updated in
            var m = owner
            if let i = m.actionItems.firstIndex(where: { $0.id == item.id }) { m.actionItems[i] = updated }
            store.update(m)
        } delete: {
            var m = owner
            m.actionItems.removeAll { $0.id == item.id }
            store.update(m)
        }
    }

    private func add() {
        let t = newTask.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var m = meeting
        m.actionItems.append(ActionItem(task: t, isManual: true))
        store.update(m)
        newTask = ""
    }
}

struct ActionItemRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    let item: ActionItem
    let meeting: Meeting
    /// Show which meeting the item came from. On for lists that aren't already grouped by meeting.
    var showMeeting = false
    let update: (ActionItem) -> Void
    let delete: () -> Void
    @State private var showingCalendar = false
    @State private var expanded = false

    private var advising: Bool { pipeline.isAdvising(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: Binding(get: { item.done }, set: { var i = item; i.done = $0; update(i) }))
                    .toggleStyle(.checkbox).labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                    caption
                }
                Spacer()
                guidanceButton
            }
            if expanded, let guidance = item.guidance { GuidancePanel(item: item, text: guidance, meeting: meeting) }
            if let error = pipeline.adviceErrors[item.id] {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { pipeline.adviceErrors[item.id] = nil }.buttonStyle(.link)
                }
                .font(.caption)
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(item.guidance == nil ? "Suggest How to Handle This" : "Suggest How to Handle This Again") { requestGuidance() }
                .disabled(advising)
            Button("Add to Calendar…") { showingCalendar = true }
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
            AddToCalendarPopover(draft: EventDraft(item: item, meeting: meeting), offerReminders: true,
                                 alreadyAdded: item.calendarAddedAt != nil) { _ in
                var i = item
                i.calendarAddedAt = Date()
                update(i)
            }
        }
    }

    private var caption: some View {
        HStack(spacing: 8) {
            if let owner = item.owner, !owner.isEmpty { Label(owner, systemImage: "person") }
            if item.dueLabel != nil || item.calendarAddedAt != nil {
                DueDateChip(item: item, meeting: meeting, update: update)
            }
            if showMeeting {
                Label("\(meeting.title) · \(Fmt.dateOnly.string(from: meeting.startedAt))", systemImage: "text.bubble")
                    .lineLimit(1)
            }
            if let revisited = item.lastDiscussedMeetingID, let last = store.meeting(revisited), last.id != meeting.id {
                Text("· still open")
                    .help("Came up again in “\(last.title)” on \(Fmt.dateOnly.string(from: last.startedAt))")
            }
            if item.isManual { Text("added by you").italic() }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var guidanceButton: some View {
        if advising {
            ProgressView().controlSize(.small)
                .help("Working out how to handle this…")
        } else if item.guidance != nil {
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "lightbulb.fill" : "lightbulb")
            }
            .buttonStyle(.borderless)
            .help(expanded ? "Hide the suggestion" : "Show how to handle this")
        } else {
            Button(action: requestGuidance) { Image(systemName: "wand.and.stars") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Suggest how to handle this — asks the model, using this meeting and the project context")
        }
    }

    private func requestGuidance() {
        expanded = true
        pipeline.requestGuidance(for: item, in: meeting)
    }
}

/// The model's answer to "how would you handle this", shown under the item that asked for it.
struct GuidancePanel: View {
    @EnvironmentObject var pipeline: Pipeline
    let item: ActionItem
    let text: String
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Suggested approach", systemImage: "lightbulb")
                    .font(.caption.weight(.semibold))
                if let at = item.guidanceAt {
                    Text(Fmt.dateOnly.string(from: at)).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Regenerate") { pipeline.requestGuidance(for: item, in: meeting) }
                    .disabled(pipeline.isAdvising(item.id))
                Button("Copy") { Clipboard.copy(text) }
            }
            .buttonStyle(.link)
            .font(.caption)
            MarkdownView(markdown: text)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        .padding(.leading, 26)
    }
}

// MARK: - Notes

struct NotesTab: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    @State private var text = ""
    @State private var loadedFor: UUID?

    var body: some View {
        VStack(spacing: 0) {
            TabBar(copy: CopyButton(title: "Copy notes", disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { text }) {
                Text("Your own notes — saved automatically").foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.body)
                .padding(8)
        }
        .onAppear(perform: load)
        .onChange(of: meeting.id) { _, _ in load() }
        .onChange(of: text) { _, new in
            if loadedFor == meeting.id { store.saveNotes(new, for: meeting) }
        }
    }

    private func load() {
        loadedFor = nil
        text = store.notes(for: meeting)
        loadedFor = meeting.id
    }
}
