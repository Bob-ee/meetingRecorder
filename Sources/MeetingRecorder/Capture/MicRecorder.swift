import Foundation
import MeetingCore
import MeetingEngine
import AVFoundation

/// Records the default input device via AVAudioEngine as a mono track. When echo cancellation is on,
/// Apple's voice-processing unit strips speaker output out of the mic signal so remote participants
/// don't leak into the "You" track. (Voice processing can report odd multi-channel formats — e.g. nine
/// identical channels — which is why everything is mixed down to mono before hitting disk. It also
/// ducks other system audio, which we turn down to the minimum the API allows.)
///
/// CoreAudio can take the input away mid-recording — a route change, another app grabbing the device,
/// or voice processing reconfiguring the audio graph. AVAudioEngine reports that by posting
/// `AVAudioEngineConfigurationChange` and quietly stopping; the tap simply never fires again. The
/// engine is rebuilt when that happens, and again if the watchdog notices buffers have stopped.
final class MicRecorder {
    private(set) var isRunning = false
    private var engine: AVAudioEngine?
    private var writer: TimelineWriter?
    private var observer: NSObjectProtocol?
    private var voiceProcessing = false
    let delivery = DeliveryMonitor()
    var levelHandler: ((Float) -> Void)?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(writingTo url: URL, clock: RecordingClock, echoCancellation: Bool) throws {
        guard !isRunning else { return }
        voiceProcessing = echoCancellation
        let (engine, format) = try makeEngine()
        let writer = try TimelineWriter(url: url, sampleRate: format.sampleRate, clock: clock)
        do {
            try attach(engine, format: format, to: writer)
        } catch {
            writer.finish(totalSeconds: 0)
            throw error
        }
        self.engine = engine
        self.writer = writer
        isRunning = true
        observeConfigurationChanges()
    }

    /// Rebuilds the engine around the track already being written. The writer keeps its place on the
    /// recording clock, so whatever was missed lands as silence instead of shifting the rest of the
    /// track out of sync with the system-audio one.
    @discardableResult
    func restart() -> Bool {
        guard isRunning, let writer else { return false }
        stopEngine()
        do {
            let (engine, format) = try makeEngine()
            if format.sampleRate != writer.sampleRate {
                Log.capture.notice("mic came back at \(format.sampleRate) Hz — resampling to the track's \(writer.sampleRate) Hz")
            }
            try attach(engine, format: format, to: writer)
            self.engine = engine
            Log.capture.notice("mic capture restarted")
            return true
        } catch {
            Log.capture.error("mic restart failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns seconds of audio written.
    @discardableResult
    func stop(totalSeconds: Double) -> Double {
        guard isRunning else { return 0 }
        isRunning = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        stopEngine()
        writer?.finish(totalSeconds: totalSeconds)
        let seconds = writer?.seconds ?? 0
        writer = nil
        return seconds
    }

    private func makeEngine() throws -> (AVAudioEngine, AVAudioFormat) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The voice-processing unit ducks everything else the machine is playing — the same
                // way a FaceTime call quiets your music — and Apple exposes no way to turn that off;
                // `.min` is the floor and it is still plainly audible. That is why this is off by
                // default and why echo is dealt with after the fact, in TranscriptionService.
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            } catch {
                Log.capture.error("voice processing unavailable: \(error.localizedDescription)")
            }
        }
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0 {
            try? input.setVoiceProcessingEnabled(false)
            format = input.outputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MicRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No usable microphone input format"])
        }
        Log.capture.notice("mic input format: \(format.sampleRate) Hz, \(format.channelCount) ch, voiceProcessing=\(input.isVoiceProcessingEnabled)")
        return (engine, format)
    }

    private func attach(_ engine: AVAudioEngine, format: AVAudioFormat, to writer: TimelineWriter) throws {
        let input = engine.inputNode
        let levelHandler = self.levelHandler
        let delivery = self.delivery
        delivery.begin()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            delivery.mark()
            writer.write(buffer, hostTime: when.isHostTimeValid ? when.hostTime : 0)
            if let levelHandler { levelHandler(AudioMix.rms(buffer)) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func observeConfigurationChanges() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isRunning, (note.object as AnyObject?) === self.engine else { return }
            Log.capture.warning("mic engine was reconfigured mid-recording — rebuilding it")
            self.restart()
        }
    }
}
