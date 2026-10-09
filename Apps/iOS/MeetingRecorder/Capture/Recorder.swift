import AVFoundation
import Foundation
import MeetingCore

/// A finished recording, before it has become a meeting.
struct Recording {
    let id: UUID
    let file: URL
    let startedAt: Date
    let duration: TimeInterval
}

/// Records the room through the device's microphone, straight to AAC — an hour is about 30 MB, small enough
/// to upload over a phone connection. Recording carries on with the screen locked or the app in the
/// background; a phone call or Siri pauses it, and it picks up again when the system says it may.
@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0…1, for the level meter.
    @Published private(set) var level: Double = 0
    @Published var lastError: String?

    var onFinished: ((Recording) -> Void)?

    private let directory: URL
    private var recorder: AVAudioRecorder?
    private var isStarting = false
    private var current: (id: UUID, startedAt: Date)?
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []

    init(directory: URL) {
        self.directory = directory
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start() async {
        guard !isRecording, !isStarting else { return }
        lastError = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Meeting Recorder isn't allowed to use the microphone. Turn it on in Settings → Privacy & Security → Microphone."
            return
        }
        isStarting = true
        defer { isStarting = false }
        let id = UUID()
        let file = directory.appendingPathComponent("\(id.uuidString).m4a")
        do {
            // Waking the audio hardware can take a noticeable moment; the interface shouldn't wait on it.
            let recorder = try await Task.detached { try Self.begin(recordingTo: file) }.value.recorder
            recorder.delegate = self
            self.recorder = recorder
            current = (id, Date())
            isRecording = true
            isPaused = false
            elapsed = 0
            observeSession()
            startTicker()
        } catch {
            lastError = "Couldn't start recording: \(error.localizedDescription)"
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// A recorder on its way back to the main actor, which is the only place it is used from then on.
    private struct Started: @unchecked Sendable {
        let recorder: AVAudioRecorder
    }

    private nonisolated static func begin(recordingTo file: URL) throws -> Started {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let recorder = try AVAudioRecorder(url: file, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.couldNotStart }
        return Started(recorder: recorder)
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        isPaused = true
        level = 0
    }

    func resume() {
        guard isRecording, isPaused else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            guard recorder?.record() == true else { throw RecorderError.couldNotStart }
            isPaused = false
        } catch {
            lastError = "Couldn't resume recording: \(error.localizedDescription)"
        }
    }

    /// Finish and hand the recording on.
    func stop() {
        guard let recorder, let current else { return }
        let duration = recorder.currentTime
        let file = recorder.url
        recorder.stop()
        reset()
        onFinished?(Recording(id: current.id, file: file, startedAt: current.startedAt, duration: duration))
    }

    /// Finish and throw the recording away.
    func discard() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        reset()
    }

    private func reset() {
        ticker?.invalidate()
        ticker = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        recorder = nil
        current = nil
        isRecording = false
        isPaused = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let recorder, !isPaused else { return }
        elapsed = recorder.currentTime
        recorder.updateMeters()
        // averagePower is in dB, 0 at full scale; speech across a room sits around -40 to -10.
        level = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
    }

    // MARK: - Interruptions

    private func observeSession() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
                MainActor.assumeIsolated { self?.interrupted(type, mayResume: options?.contains(.shouldResume) ?? false) }
            },
            // Unplugging a headset can stop the recorder; it carries on with whatever input is left.
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.routeChanged() }
            },
        ]
    }

    /// The system pauses the recorder itself when a call comes in. If it says recording may carry on once the
    /// call is over, it does; otherwise it stays paused for the user to resume.
    private func interrupted(_ type: AVAudioSession.InterruptionType?, mayResume: Bool) {
        guard isRecording else { return }
        switch type {
        case .began:
            isPaused = true
            level = 0
        case .ended where mayResume:
            resume()
        default:
            break
        }
    }

    private func routeChanged() {
        guard isRecording, !isPaused, let recorder, !recorder.isRecording else { return }
        if !recorder.record() { isPaused = true }
    }
}

extension Recorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "unknown error"
        Task { @MainActor in self.lastError = "Recording stopped: \(message)" }
    }
}

private enum RecorderError: LocalizedError {
    case couldNotStart
    var errorDescription: String? { "the microphone is busy or unavailable" }
}
