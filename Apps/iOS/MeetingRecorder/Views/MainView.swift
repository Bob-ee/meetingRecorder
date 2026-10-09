import MeetingCore
import SwiftUI

enum SidebarItem: Hashable {
    case all
    case actionItems
    case project(UUID)
}

/// Sidebar, list, meeting — three columns on an iPad, a stack of screens on an iPhone.
struct MainView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var recorder: Recorder
    @State private var sidebar: SidebarItem?
    @State private var selectedMeetingID: UUID?
    @State private var searchText = ""
    @State private var showingRecorder = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var currentProjectID: UUID? {
        if case .project(let id) = sidebar { return id }
        return nil
    }

    private var contentTitle: String {
        switch sidebar {
        case .actionItems: return "Action Items"
        case .project(let id): return library.project(id)?.project.name ?? "Project"
        default: return "All Meetings"
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar)
                // On an iPhone the sidebar is a screen of its own; on an iPad the list beside it has the button.
                .floating(sizeClass == .compact ? RecordButton(record: record) : nil)
        } content: {
            Group {
                if sidebar == .actionItems {
                    ActionItemsOverview(selectedMeetingID: $selectedMeetingID)
                } else {
                    Group {
                        if let projectID = currentProjectID {
                            ProjectContent(projectID: projectID, searchText: searchText, selection: $selectedMeetingID)
                        } else {
                            MeetingListView(projectID: nil, searchText: searchText, selection: $selectedMeetingID)
                        }
                    }
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search meetings")
                }
            }
            .floating(RecordButton(record: record))
            .navigationTitle(contentTitle)
        } detail: {
            if let id = selectedMeetingID, library.meeting(id) != nil {
                MeetingDetailView(meetingID: id)
            } else {
                EmptyDetailView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if recorder.isRecording, !showingRecorder { RecordingBanner { showingRecorder = true } }
        }
        .sheet(isPresented: $showingRecorder) { RecordingSheet() }
        // Chosen once the view is up rather than as the initial value: an iPhone that starts with the list
        // already pushed draws it without its title.
        .onAppear { if sidebar == nil { sidebar = .all } }
        .onChange(of: sidebar) { _, _ in
            // A meeting from another project shouldn't stay open beside this project's list.
            if let id = selectedMeetingID, let pid = currentProjectID, library.meeting(id)?.projectID != pid {
                selectedMeetingID = nil
            }
        }
    }

    private func record() {
        if !recorder.isRecording { app.startRecording(in: currentProjectID) }
        showingRecorder = true
    }
}

/// The Record button, floating at the bottom of a list where a thumb reaches it. While a recording is running
/// it shows the time instead, and brings the recording sheet back.
struct RecordButton: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var recorder: Recorder
    let record: () -> Void

    var body: some View {
        Button(action: record) {
            Group {
                if recorder.isRecording {
                    Label(Fmt.timestamp(recorder.elapsed), systemImage: "waveform").monospacedDigit()
                } else {
                    Label("Record", systemImage: "record.circle.fill")
                }
            }
            .font(.headline)
            .padding(.horizontal, 22).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(Capsule().fill(.red))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        // Until the first sync there is no project for a recording to go into.
        .disabled(library.projects.isEmpty && !recorder.isRecording)
        .padding(.bottom, 8)
    }
}

private extension View {
    /// Float `button` over the bottom of a list, leaving room to scroll the last row clear of it.
    func floating(_ button: RecordButton?) -> some View {
        contentMargins(.bottom, button == nil ? 0 : 72, for: .scrollContent)
            .overlay(alignment: .bottom) { button }
    }
}

/// A project's middle column: its meetings, or everything the project is still waiting on.
struct ProjectContent: View {
    @EnvironmentObject var library: Library
    let projectID: UUID
    let searchText: String
    @Binding var selection: UUID?
    @State private var tab: Tab = .meetings
    @State private var showingInfo = false

    enum Tab: String, CaseIterable, Identifiable {
        case meetings = "Meetings", actions = "Action Items"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    if t == .actions {
                        let open = library.meetings(in: projectID).reduce(0) { $0 + $1.openActionItems.count }
                        Text(open > 0 ? "\(t.rawValue)  \(open)" : t.rawValue).tag(t)
                    } else {
                        Text(t.rawValue).tag(t)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal).padding(.vertical, 8)
            switch tab {
            case .meetings:
                MeetingListView(projectID: projectID, searchText: searchText, selection: $selection)
            case .actions:
                ActionItemsOverview(projectID: projectID, selectedMeetingID: $selection)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingInfo = true } label: { Label("Project Context", systemImage: "doc.text") }
            }
        }
        .sheet(isPresented: $showingInfo) { ProjectInfoView(projectID: projectID) }
        .onChange(of: projectID) { _, _ in tab = .meetings }
    }
}

struct EmptyDetailView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Select a meeting", systemImage: "waveform.badge.mic")
        } description: {
            Text("Hit Record when a meeting starts, or share a recording into Meeting Recorder from Voice Memos or Files. Your hub transcribes and summarizes it, and it shows up on all your devices.")
        }
    }
}
