import MeetingCore
import MeetingSync
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var uploader: Uploader
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID

    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript", actions = "Actions", notes = "Notes" }
    @State private var tab: Tab = .summary
    @State private var title = ""
    @State private var confirmingDelete = false
    @FocusState private var editingTitle: Bool

    var body: some View {
        if let record = library.record(meetingID) {
            let meeting = record.meeting
            VStack(alignment: .leading, spacing: 0) {
                header(meeting)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal).padding(.bottom, 8)
                Divider()
                Group {
                    switch tab {
                    case .summary: SummaryTab(meeting: meeting)
                    case .transcript: TranscriptTab(meeting: meeting)
                    case .actions: ActionItemsTab(meeting: meeting)
                    case .notes: NotesTab(meetingID: meetingID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar(record) }
            .onAppear { title = meeting.title }
            .onChange(of: meetingID) { _, _ in title = library.meeting(meetingID)?.title ?? ""; tab = .summary }
            .onChange(of: meeting.title) { _, new in if title != new { title = new } }
            .confirmationDialog("Delete “\(meeting.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Meeting", role: .destructive) {
                    app.delete(meeting: meetingID)
                    dismiss()
                }
            } message: {
                Text("Its recording, transcript and notes are deleted on every device.")
            }
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Meeting title", text: $title)
                .font(.title2.weight(.semibold))
                .submitLabel(.done)
                .focused($editingTitle)
                // Leaving the field is as good as pressing Done.
                .onChange(of: editingTitle) { _, editing in if !editing { library.rename(meeting: meetingID, to: title) } }
            HStack(spacing: 6) {
                Text(Fmt.dateTime.string(from: meeting.startedAt))
                if meeting.durationSeconds > 0 { Text("·"); Text(Fmt.duration(meeting.durationSeconds)) }
                if let project = library.project(meeting.projectID) { Text("·"); Label(project.project.name, systemImage: "folder") }
            }
            .labelStyle(.caption)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            HStack(spacing: 8) {
                MeetingStatusView(meeting: meeting)
                if let progress = app.jobProgress[meeting.id], meeting.status.isBusy {
                    Text(progress).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            problem(meeting)
        }
        .padding(.horizontal).padding(.top, 8).padding(.bottom, 10)
    }

    /// Whatever went wrong, with the way to try again: the upload if it never left, the processing if it did.
    @ViewBuilder
    private func problem(_ meeting: Meeting) -> some View {
        if case .failed(let why)? = uploader.state(for: meeting.id) {
            ProblemBanner(text: why) { uploader.resume() }
        } else if meeting.status == .failed, let why = meeting.errorMessage {
            ProblemBanner(text: why) {
                let hasTranscript = !library.content(for: meetingID).transcript.isEmpty
                app.reprocess(meetingID, steps: hasTranscript ? [.summarize] : JobStep.allCases)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ record: MeetingRecord) -> some ToolbarContent {
        let meeting = record.meeting
        let content = library.content(for: meetingID)
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ShareLink("Everything", item: MeetingDocuments.everything(
                    meeting: meeting, projectName: library.project(meeting.projectID)?.project.name,
                    summaryMarkdown: content.summary, notes: record.notes, transcript: content.transcript))
                if let summary = content.summary {
                    ShareLink("Summary", item: MeetingDocuments.summaryExport(
                        summaryMarkdown: summary, actionItems: meeting.actionItems, events: meeting.events))
                }
                if !content.transcript.isEmpty {
                    ShareLink("Transcript", item: MeetingDocuments.transcriptMarkdown(content.transcript, meeting: meeting))
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Menu {
                Menu("Move to Project") {
                    ForEach(library.projects.filter { $0.id != meeting.projectID }) { project in
                        Button(project.project.name) { library.move(meeting: meetingID, to: project.id) }
                    }
                }
                Divider()
                Button("Re-summarize") { app.reprocess(meetingID, steps: [.summarize]) }
                    .disabled(content.transcript.isEmpty)
                Button("Re-transcribe & Summarize") { app.reprocess(meetingID, steps: JobStep.allCases) }
                    .disabled(uploader.state(for: meetingID) != nil)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

struct ProblemBanner: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).textSelection(.enabled)
            Spacer()
            Button("Retry", action: retry).buttonStyle(.bordered).controlSize(.small)
        }
        .font(.footnote)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.1)))
    }
}
