import MeetingCore
import MeetingEngine
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings: AppSettings
    let store: Store
    let recorder: Recorder
    let pipeline: Pipeline
    let hub: HubSync
    let detector: MeetingDetector
    private let watcher = FolderWatcher()
    private var pendingSizes: [URL: Int] = [:]

    @Published var detectedApp: String?
    @Published var requestNewProject = false
    @Published var selectedProjectID: UUID?
    @Published var modelStatus: String?
    @Published var importError: String?

    private init() {
        let settings = AppSettings()
        let store = Store(rootURL: settings.storageRootURL)
        self.settings = settings
        self.store = store
        self.recorder = Recorder(store: store, settings: settings)
        self.pipeline = Pipeline(store: store, settings: settings)
        self.hub = HubSync(store: store, settings: settings, pipeline: pipeline)
        self.detector = MeetingDetector()
        pipeline.hub = hub
        store.onChange = { [weak self] change in self?.hub.noteChange(change) }
        hub.configure()

        recorder.onStopped = { [weak self] meeting in self?.pipeline.run(meeting) }
        detector.isRecordingProvider = { [weak self] in self?.recorder.isRecording ?? false }
        detector.onDetected = { [weak self] app in self?.handleDetection(app) }
        if settings.autoDetect { detector.start() }
        pipeline.resumeUnfinished()

        watcher.onChange = { [weak self] in self?.scanDroppedFiles() }
        rewatchFolders()
        scanDroppedFiles()
    }

    // MARK: Folder watching (drop a recording into ~/Meetings/<Project>/ in Finder)

    func rewatchFolders() {
        watcher.watch([store.rootURL] + store.projectFolderURLs)
    }

    func scanDroppedFiles() {
        store.pruneMissing()
        store.adoptNewProjectFolders()
        rewatchFolders()
        let loose = store.looseAudioFiles()
        var stillGrowing = false
        for (projectID, url) in loose {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if let previous = pendingSizes[url], previous == size, size > 0 {
                // Unchanged since the last look: the copy has finished.
                pendingSizes[url] = nil
                importAudio(urls: [url], into: projectID, move: true)
            } else {
                pendingSizes[url] = size
                stillGrowing = true
            }
        }
        if stillGrowing {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.scanDroppedFiles()
            }
        }
    }

    // MARK: Recording

    var defaultProjectID: UUID {
        if let id = selectedProjectID, store.project(id) != nil { return id }
        if let id = UUID(uuidString: settings.lastProjectID), store.project(id) != nil { return id }
        return store.inboxProject.id
    }

    func startRecording(projectID: UUID?, title: String? = nil) {
        let pid = projectID ?? defaultProjectID
        detectedApp = nil
        Notifier.clearDetected()
        Task { await recorder.start(projectID: pid, title: title) }
    }

    private func handleDetection(_ app: String) {
        detectedApp = app
        Notifier.meetingDetected(app: app)
    }

    func recordFromDetection() {
        let app = detectedApp
        startRecording(projectID: nil, title: app.map { "\($0) meeting" })
        openMainWindow()
    }

    func dismissDetection() {
        detectedApp = nil
        Notifier.clearDetected()
    }

    func setAutoDetect(_ on: Bool) {
        settings.autoDetect = on
        if on { detector.start() } else { detector.stop(); detectedApp = nil }
    }

    // MARK: Window

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true || $0.title == "Meeting Recorder" }) {
            window.makeKeyAndOrderFront(nil)
        } else if let url = URL(string: "meetingrecorder://open") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Import

    func importAudio() {
        let panel = NSOpenPanel()
        panel.title = "Import a recording"
        panel.allowedContentTypes = [.audio, .mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importAudio(urls: panel.urls, into: nil, move: false)
    }

    /// Import recordings into `projectID` (nil = selected / last used / Inbox) and run the full pipeline.
    /// `move` is used for files that are already inside our storage folder.
    func importAudio(urls: [URL], into projectID: UUID?, move: Bool) {
        let pid = projectID ?? defaultProjectID
        for url in urls where AudioImporter.isAudioFile(url) {
            Task { await self.importOne(url, into: pid, move: move) }
        }
    }

    private func importOne(_ url: URL, into projectID: UUID, move: Bool) async {
        let recorded = AudioImporter.recordingDate(of: url)
        let title = url.deletingPathExtension().lastPathComponent
        var meeting = store.createMeeting(in: projectID, title: title, source: .imported, startedAt: recorded)
        pipeline.setProgress(meeting.id, "Importing \(url.lastPathComponent)…")
        do {
            let staged = try await AudioImporter.stage(url, into: store.folder(for: meeting), move: move)
            guard var fresh = store.meeting(meeting.id) else { return }
            fresh.importedFileName = staged.fileName
            fresh.titleIsAuto = true
            fresh.durationSeconds = staged.duration
            store.update(fresh)
            meeting = fresh
        } catch {
            store.deleteMeeting(meeting.id)
            pipeline.setProgress(meeting.id, nil)
            importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            Log.pipeline.error("import failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }
        pipeline.setProgress(meeting.id, nil)
        pipeline.run(meeting)
    }

    // MARK: Models

    func downloadModels() {
        guard modelStatus == nil else { return }
        modelStatus = "Preparing…"
        let version = TranscriptionService.modelVersion(from: settings.asrVersion)
        Task {
            do {
                try await TranscriptionService.shared.prepare(version: version) { text in
                    Task { @MainActor in self.modelStatus = text }
                }
                modelStatus = "Models ready"
            } catch {
                modelStatus = "Failed: \(error.localizedDescription)"
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            modelStatus = nil
        }
    }
}


