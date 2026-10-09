import MeetingCore
import MeetingSync
import SwiftUI

struct MeetingListView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var connection: HubConnection
    let projectID: UUID?
    let searchText: String
    @Binding var selection: UUID?
    @State private var deleting: Meeting?

    private var meetings: [Meeting] { library.search(searchText, in: projectID) }

    var body: some View {
        List(selection: $selection) {
            ForEach(meetings) { meeting in
                MeetingRow(meeting: meeting)
                    .tag(meeting.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = meeting }
                    }
                    .contextMenu { contextMenu(meeting) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if meetings.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                           description: Text("Record one, or share a recording into the app."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .refreshable { await connection.sync() }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Meeting", role: .destructive) {
                if let meeting = deleting {
                    if selection == meeting.id { selection = nil }
                    app.delete(meeting: meeting.id)
                }
                deleting = nil
            }
        } message: {
            Text("Its recording, transcript and notes are deleted on every device.")
        }
    }

    @ViewBuilder
    private func contextMenu(_ meeting: Meeting) -> some View {
        Menu("Move to Project") {
            ForEach(library.projects.filter { $0.id != meeting.projectID }) { project in
                Button(project.project.name) { library.move(meeting: meeting.id, to: project.id) }
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = meeting }
    }
}

struct MeetingRow: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var uploader: Uploader
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title).fontWeight(.medium).lineLimit(1)
                Spacer()
                MeetingStatusView(meeting: meeting)
            }
            HStack(spacing: 6) {
                Text(Fmt.dateTime.string(from: meeting.startedAt))
                if meeting.durationSeconds > 0 { Text("·"); Text(Fmt.duration(meeting.durationSeconds)) }
                let open = meeting.openActionItems.count
                if open > 0 {
                    Text("·")
                    Label("\(open)", systemImage: "checklist")
                }
                if meeting.source == .imported { Text("·"); Image(systemName: "square.and.arrow.down") }
            }
            .labelStyle(.caption)
            .font(.caption).foregroundStyle(.secondary)
            if let progress = app.jobProgress[meeting.id], meeting.status.isBusy {
                Text(progress).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Where a meeting has got to. While its recording is still on this device the answer comes from the
/// uploader — the hub can't report on something it hasn't received.
struct MeetingStatusView: View {
    @EnvironmentObject var uploader: Uploader
    let meeting: Meeting

    var body: some View {
        switch uploader.state(for: meeting.id) {
        case .waiting?:
            Chip(text: "Waiting to upload", color: .gray)
        case .uploading(let sent)?:
            Chip(text: "Uploading \(Int(sent * 100))%", color: .blue, busy: true)
        case .failed?:
            Chip(text: "Upload failed", color: .orange)
        case nil:
            StatusChip(status: meeting.status)
        }
    }
}

struct StatusChip: View {
    let status: MeetingStatus

    private var color: Color {
        switch status {
        case .recording: return .red
        case .recorded, .transcribed: return .gray
        case .uploading, .queued, .transcribing, .summarizing: return .blue
        case .ready: return .green
        case .failed: return .orange
        }
    }

    var body: some View {
        Chip(text: status.label, color: color, busy: status.isBusy)
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var busy = false

    var body: some View {
        HStack(spacing: 4) {
            if busy { ProgressView().controlSize(.mini) }
            Text(text)
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}

/// An icon tight against its text, for the small print under a title. The standard label leaves a
/// list-row's worth of space between the two, which reads as two separate things at caption size.
struct CaptionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == CaptionLabelStyle {
    static var caption: CaptionLabelStyle { CaptionLabelStyle() }
}
