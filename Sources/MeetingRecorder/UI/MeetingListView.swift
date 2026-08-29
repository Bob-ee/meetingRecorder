import SwiftUI

struct MeetingListView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var pipeline: Pipeline
    let projectID: UUID?
    let searchText: String
    @Binding var selection: UUID?
    @State private var editingContext: Project?

    private var meetings: [Meeting] { store.search(searchText, in: projectID) }

    var body: some View {
        VStack(spacing: 0) {
            if let pid = projectID, let project = store.project(pid) {
                HStack {
                    Text(project.name).font(.headline)
                    Spacer()
                    Button {
                        editingContext = project
                    } label: {
                        Label("Context", systemImage: store.projectContext(pid).isEmpty ? "doc.badge.plus" : "doc.text")
                    }
                    .help("Edit the project context Claude uses when summarizing")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
            if meetings.isEmpty {
                VStack(spacing: 8) {
                    Text(searchText.isEmpty ? "No meetings yet" : "No matches")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(meetings, selection: $selection) { meeting in
                    MeetingRow(meeting: meeting, progress: pipeline.progress[meeting.id])
                        .tag(meeting.id)
                        .contextMenu { contextMenu(meeting) }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $editingContext) { ProjectContextEditor(project: $0) }
    }

    @ViewBuilder
    private func contextMenu(_ meeting: Meeting) -> some View {
        Menu("Move to Project") {
            ForEach(store.projects.filter { $0.id != meeting.projectID }) { p in
                Button(p.name) { store.moveMeeting(meeting.id, to: p.id) }
            }
        }
        Button("Copy Everything") { Clipboard.copy(store.exportForClaude(meeting)) }
        Button("Show in Finder") { store.revealInFinder(meeting) }
        Divider()
        Button("Re-transcribe & Summarize") { pipeline.run(meeting, transcribe: true, summarize: true) }
        Button("Re-summarize") { pipeline.run(meeting, transcribe: false, summarize: true) }
            .disabled(!store.hasTranscript(meeting))
        Divider()
        Button("Move to Trash", role: .destructive) {
            if selection == meeting.id { selection = nil }
            store.deleteMeeting(meeting.id)
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let progress: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title).fontWeight(.medium).lineLimit(1)
                Spacer()
                StatusChip(status: meeting.status)
            }
            HStack(spacing: 8) {
                Text(Fmt.dateTime.string(from: meeting.startedAt))
                if meeting.durationSeconds > 0 { Text("·"); Text(Fmt.duration(meeting.durationSeconds)) }
                let open = meeting.openActionItems.count
                if open > 0 {
                    Text("·")
                    Label("\(open)", systemImage: "checklist").labelStyle(.titleAndIcon)
                }
                if meeting.source == .imported { Text("·"); Image(systemName: "square.and.arrow.down") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let progress, meeting.status.isBusy {
                Text(progress).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

struct StatusChip: View {
    let status: MeetingStatus
    var color: Color {
        switch status {
        case .recording: return .red
        case .recorded, .transcribed: return .gray
        case .transcribing, .summarizing: return .blue
        case .ready: return .green
        case .failed: return .orange
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            if status.isBusy { ProgressView().controlSize(.mini) }
            Text(status.label)
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}

enum Clipboard {
    /// Puts Markdown on the clipboard as plain text *and* as HTML/RTF, so mail clients, Google Docs,
    /// Slack, Notes, etc. paste it formatted, while editors and Claude still get clean Markdown.
    static func copy(_ markdown: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let html = MarkdownHTML.render(markdown)
        var rtf: Data?
        if markdown.utf8.count < 200_000,   // WebKit-based HTML import is slow on huge transcripts
           let data = html.data(using: .utf8),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil) {
            rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
        var types: [NSPasteboard.PasteboardType] = [.html, .string]
        if rtf != nil { types.insert(.rtf, at: 1) }
        pasteboard.declareTypes(types, owner: nil)
        pasteboard.setString(html, forType: .html)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
        pasteboard.setString(markdown, forType: .string)
    }
}
