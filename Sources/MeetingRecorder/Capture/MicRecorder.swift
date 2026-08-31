import Foundation
import MeetingCore
import MeetingEngine
import AVFoundation

/// Records the default input device via AVAudioEngine as a mono track. When echo cancellation is on,
/// Apple's voice-processing unit strips speaker output out of the mic signal so remote participants
/// don't leak into the "You" track. (Voice processing can report odd multi-channel formats — e.g. nine
/// identical channels — which is why everything is mixed down to mono before hitting disk. It also
/// ducks other system audio, which we turn down to the minimum the API allows.)
final class MicRecorder {
    private(set) var isRunning = false
    private var engine: AVAudioEngine?
    private var writer: TimelineWriter?
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
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The voice-processing unit ducks everything else the machine is playing — the same
                // way a FaceTime call quiets your music. Left at its default that costs the meeting
                // you're sitting in more than half its volume, so ask for the least ducking Apple offers.
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
        Log.capture.info("mic input format: \(format.sampleRate) Hz, \(format.channelCount) ch, voiceProcessing=\(input.isVoiceProcessingEnabled)")

        let writer = try TimelineWriter(url: url, sampleRate: format.sampleRate, clock: clock)
        let levelHandler = self.levelHandler
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
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
        self.engine = engine
        self.writer = writer
        isRunning = true
    }

    /// Returns seconds of audio written.
    @discardableResult
    func stop(totalSeconds: Double) -> Double {
        guard isRunning, let engine else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.finish(totalSeconds: totalSeconds)
        let seconds = writer?.seconds ?? 0
        self.engine = nil
        writer = nil
        isRunning = false
        return seconds
    }
}
