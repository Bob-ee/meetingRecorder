import SwiftUI

enum SidebarItem: Hashable {
    case all
    case actionItems
    case project(UUID)
}

struct MainView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @State private var sidebar: SidebarItem? = .all
    @State private var selectedMeetingID: UUID?
    @State private var searchText = ""
    @State private var newProjectName = ""
    @State private var dropTargeted = false

    private var dropTargetLabel: String {
        if let id = currentProjectID, let p = store.project(id) { return "Drop recording into “\(p.name)”" }
        if let p = store.project(app.defaultProjectID) { return "Drop recording into “\(p.name)”" }
        return "Drop recording to import"
    }

    private var currentProjectID: UUID? {
        if case .project(let id) = sidebar { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if recorder.isRecording { RecordingBar() }
            if let detected = app.detectedApp, !recorder.isRecording { DetectionBanner(appName: detected) }
            if let err = recorder.lastError, !recorder.isRecording { ErrorBanner(text: err) { recorder.lastError = nil } }
            if let err = app.importError { ErrorBanner(text: err) { app.importError = nil } }

            NavigationSplitView {
                SidebarView(selection: $sidebar)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } content: {
                Group {
                    if sidebar == .actionItems {
                        ActionItemsOverview(selectedMeetingID: $selectedMeetingID)
                    } else {
                        MeetingListView(projectID: currentProjectID, searchText: searchText, selection: $selectedMeetingID)
                    }
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            } detail: {
                if let id = selectedMeetingID, store.meeting(id) != nil {
                    MeetingDetailView(meetingID: id)
                } else {
                    EmptyDetailView()
                }
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search meetings")
            .toolbar { toolbarContent }
            .dropDestination(for: URL.self) { urls, _ in
                let audio = urls.filter { AudioImporter.isAudioFile($0) }
                guard !audio.isEmpty else { return false }
                app.importAudio(urls: audio, into: currentProjectID, move: false)
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.06)))
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.down").font(.system(size: 36))
                                Text(dropTargetLabel).font(.title3.weight(.semibold))
                                Text("It'll be transcribed and summarized automatically").foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: sidebar) { _, newValue in
            if case .project(let id) = newValue { app.selectedProjectID = id } else { app.selectedProjectID = nil }
            if let id = selectedMeetingID, let m = store.meeting(id), let pid = currentProjectID, m.projectID != pid {
                selectedMeetingID = nil
            }
        }
        .alert("New Project", isPresented: $app.requestNewProject) {
            TextField("Project name", text: $newProjectName)
            Button("Create") {
                let name = newProjectName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    let p = store.createProject(name: name)
                    sidebar = .project(p.id)
                }
                newProjectName = ""
            }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        } message: {
            Text("Projects group related meetings, like Claude projects group chats.")
        }
        .onOpenURL { _ in }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if recorder.isRecording {
                Button {
                    recorder.stop()
                } label: {
                    Label("Stop  \(Fmt.duration(recorder.elapsed))", systemImage: "stop.circle.fill")
                }
                .tint(.red)
                .help("Stop recording")
            } else {
                Menu {
                    ForEach(store.projects) { p in
                        Button("Record into “\(p.name)”") { app.startRecording(projectID: p.id) }
                    }
                } label: {
                    Label("Record", systemImage: "record.circle")
                } primaryAction: {
                    app.startRecording(projectID: currentProjectID)
                }
                .help("Start recording the current meeting (⇧⌘R)")
            }
            Button {
                app.importAudio()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import an existing recording (e.g. a Zoom local recording)")
        }
    }
}

struct EmptyDetailView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Select a meeting")
                .font(.title2)
            Text("Hit Record when a call starts — or let the app notice the microphone turning on and prompt you. Drop a recording from your phone here (or into the project's folder in Finder) and it gets the same treatment.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("Everything is stored as plain Markdown in \(store.rootURL.path)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DetectionBanner: View {
    @EnvironmentObject var app: AppState
    let appName: String
    var body: some View {
        HStack {
            Image(systemName: "mic.badge.plus").foregroundStyle(.orange)
            Text("\(appName) is using the microphone — meeting starting?")
            Spacer()
            Button("Record") { app.recordFromDetection() }.buttonStyle(.borderedProminent)
            Button("Dismiss") { app.dismissDetection() }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.red.opacity(0.1))
    }
}
