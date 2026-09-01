import Foundation
import MeetingCore
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
    /// Set while a track has stopped delivering and could not be brought back — shown in the recording
    /// bar so a meeting is never silently lost to a dead capture.
    @Published private(set) var captureWarning: String?

    var isRecording: Bool { current != nil }
    var onStopped: ((Meeting) -> Void)?

    private let store: Store
    private let settings: AppSettings
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var timer: Timer?
    private var startDate: Date?
    private var clock: RecordingClock?
    private var micRestarts = 0
    private var systemRestarts = 0
    private var systemStoppedChecks = 0
    /// The mic device runs continuously, so a couple of seconds without a buffer means we were dropped.
    private static let micStallTimeout: TimeInterval = 2.5
    /// Voice processing can take a second or two to hand over the first buffer, so give a track that has
    /// never delivered longer before deciding it is stuck.
    private static let startupGrace: TimeInterval = 6
    /// Two consecutive bad reads, so a single sample taken while CoreAudio is mid-handover is not enough
    /// to tear a healthy tap down.
    private static let systemStoppedChecksBeforeRestart = 2
    /// Enough to ride out a device switch, few enough that a genuinely broken device stops thrashing.
    private static let maxRestarts = 5

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

        // The microphone goes first. Turning on voice processing makes CoreAudio rebuild the output
        // device's streams, and that stops the IO thread any process tap is running on — a tap created
        // beforehand is left dead for the rest of the meeting. Starting the tap afterwards builds it on
        // a graph that has already settled.
        if micGranted {
            do {
                try mic.start(writingTo: store.micURL(for: meeting), clock: clock, echoCancellation: settings.echoCancellation)
                micActive = true
            } catch {
                micActive = false
                Log.capture.error("mic start failed: \(error.localizedDescription)")
                problems.append("Microphone: \(error.localizedDescription)")
            }
        } else {
            micActive = false
            problems.append("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
        }

        do {
            try system.start(writingTo: store.systemURL(for: meeting), clock: clock)
            systemActive = true
        } catch {
            systemActive = false
            Log.capture.error("system audio start failed: \(error.localizedDescription)")
            problems.append("System audio: \(error.localizedDescription). Grant “System Audio Recording” in System Settings → Privacy & Security → Screen & System Audio Recording.")
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
        captureWarning = nil
        micRestarts = 0
        systemRestarts = 0
        systemStoppedChecks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
                self.checkTracks()
            }
        }
    }

    /// Watches for a track CoreAudio has stopped feeding us and rebuilds it. Either track can die with no
    /// error reported — the buffers just stop and the rest of the file becomes silence — so the recording
    /// has to notice for itself.
    private func checkTracks() {
        guard isRecording else { return }
        var dead: [String] = []

        let micLimit = mic.delivery.hasDelivered ? Self.micStallTimeout : Self.startupGrace
        if micActive, mic.delivery.silentFor > micLimit {
            Log.capture.warning("microphone stopped delivering audio — rebuilding it")
            if micRestarts < Self.maxRestarts, mic.restart() {
                micRestarts += 1
            } else {
                micActive = false
                dead.append("the microphone")
            }
        }

        // A quiet tap is normal — nothing is playing. A stopped one is not. Only the device's own running
        // flag can tell those apart, and it reads false while CoreAudio hands the device over, so wait for
        // it to stay false rather than tearing down a tap that is only mid-restart.
        if systemActive, !system.isDeviceRunning {
            systemStoppedChecks += 1
        } else {
            systemStoppedChecks = 0
        }
        if systemActive, systemStoppedChecks >= Self.systemStoppedChecksBeforeRestart {
            systemStoppedChecks = 0
            Log.capture.warning("system audio device stopped running — rebuilding the tap")
            if systemRestarts < Self.maxRestarts, system.restart() {
                systemRestarts += 1
            } else {
                systemActive = false
                dead.append("system audio")
            }
        }

        if !dead.isEmpty {
            let lost = dead.joined(separator: " and ")
            captureWarning = "Not capturing \(lost) any more. Stop and start the recording to try again."
            Log.capture.error("capture lost: \(lost)")
        }
    }

    func stop() {
        guard var meeting = current else { return }
        timer?.invalidate(); timer = nil
        let total = clock?.elapsedNow() ?? elapsed
        let micSeconds = mic.stop(totalSeconds: total)
        let systemSeconds = system.stop(totalSeconds: total)
        Log.capture.notice("stopped after \(total)s — mic track \(micSeconds)s, system track \(systemSeconds)s")
        if micRestarts > 0 || systemRestarts > 0 {
            Log.capture.notice("capture was rebuilt mid-recording — mic \(micRestarts)×, system \(systemRestarts)×")
        }
        micActive = false; systemActive = false
        micLevel = 0; systemLevel = 0
        captureWarning = nil
        clock = nil
        meeting.durationSeconds = total
        meeting.status = .recorded
        store.update(meeting)
        current = nil
        startDate = nil
        onStopped?(meeting)
    }
}
