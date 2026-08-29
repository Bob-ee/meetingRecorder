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
            VStack(spacing: 0) {
                TabBar(copy: CopyButton(title: "Copy summary") { store.summaryExport(for: meeting) ?? md }) {
                    Text("Overview, decisions, action items and open questions").foregroundStyle(.secondary)
                }
                ScrollView {
                    MarkdownView(markdown: store.summaryExport(for: meeting) ?? md)
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
            if meeting.actionItems.isEmpty {
                Text("No action items").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(meeting.actionItems) { item in
                        ActionItemRow(item: item) { updated in
                            var m = meeting
                            if let i = m.actionItems.firstIndex(where: { $0.id == item.id }) { m.actionItems[i] = updated }
                            store.update(m)
                        } delete: {
                            var m = meeting
                            m.actionItems.removeAll { $0.id == item.id }
                            store.update(m)
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
    let item: ActionItem
    let update: (ActionItem) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { item.done }, set: { var i = item; i.done = $0; update(i) }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                HStack(spacing: 8) {
                    if let owner = item.owner, !owner.isEmpty { Label(owner, systemImage: "person") }
                    if let due = item.due, !due.isEmpty { Label(due, systemImage: "calendar") }
                    if item.isManual { Text("added by you").italic() }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu { Button("Delete", role: .destructive, action: delete) }
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
