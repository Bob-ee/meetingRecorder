import Foundation
import AVFoundation

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var current: Meeting?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var lastError: String?
    @Published private(set) var micActive = false
    @Published private(set) var systemActive = false

    var isRecording: Bool { current != nil }
    var onStopped: ((Meeting) -> Void)?

    private let store: Store
    private let settings: AppSettings
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var timer: Timer?
    private var startDate: Date?
    private var clock: RecordingClock?

    init(store: Store, settings: AppSettings) {
        self.store = store
        self.settings = settings
        mic.levelHandler = { [weak self] level in
            DispatchQueue.main.async { self?.micLevel = level }
        }
        system.levelHandler = { [weak self] level in
            DispatchQueue.main.async { self?.systemLevel = level }
        }
    }

    func start(projectID: UUID, title: String? = nil) async {
        guard !isRecording else { return }
        lastError = nil
        let micGranted = await MicRecorder.requestPermission()
        var meeting = store.createMeeting(in: projectID, title: title ?? "Meeting", source: .live)
        var problems: [String] = []
        let clock = RecordingClock()
        self.clock = clock

        do {
            try system.start(writingTo: store.systemURL(for: meeting), clock: clock)
            systemActive = true
        } catch {
            systemActive = false
            Log.capture.error("system audio start failed: \(error.localizedDescription, privacy: .public)")
            problems.append("System audio: \(error.localizedDescription). Grant “System Audio Recording” in System Settings → Privacy & Security → Screen & System Audio Recording.")
        }

        if micGranted {
            do {
                try mic.start(writingTo: store.micURL(for: meeting), clock: clock, echoCancellation: settings.echoCancellation)
                micActive = true
            } catch {
                micActive = false
                Log.capture.error("mic start failed: \(error.localizedDescription, privacy: .public)")
                problems.append("Microphone: \(error.localizedDescription)")
            }
        } else {
            micActive = false
            problems.append("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
        }

        guard micActive || systemActive else {
            store.deleteMeeting(meeting.id)
            lastError = problems.joined(separator: "\n")
            return
        }
        if !problems.isEmpty { lastError = problems.joined(separator: "\n") }

        meeting.status = .recording
        store.update(meeting)
        settings.lastProjectID = projectID.uuidString
        current = meeting
        startDate = Date()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    func stop() {
        guard var meeting = current else { return }
        timer?.invalidate(); timer = nil
        let total = clock?.elapsedNow() ?? elapsed
        let micSeconds = mic.stop(totalSeconds: total)
        let systemSeconds = system.stop(totalSeconds: total)
        Log.capture.info("stopped after \(total, privacy: .public)s — mic track \(micSeconds, privacy: .public)s, system track \(systemSeconds, privacy: .public)s")
        micActive = false; systemActive = false
        micLevel = 0; systemLevel = 0
        clock = nil
        meeting.durationSeconds = total
        meeting.status = .recorded
        store.update(meeting)
        current = nil
        startDate = nil
        onStopped?(meeting)
    }
}
