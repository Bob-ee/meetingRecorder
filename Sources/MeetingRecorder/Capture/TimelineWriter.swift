import Foundation
import MeetingCore
import MeetingEngine
import AVFoundation

/// Wall-clock reference shared by all tracks of one recording so they line up sample-for-sample.
struct RecordingClock {
    let startHostTime: UInt64
    init() { startHostTime = mach_absolute_time() }
    func elapsed(atHostTime t: UInt64) -> Double {
        AVAudioTime.seconds(forHostTime: t) - AVAudioTime.seconds(forHostTime: startHostTime)
    }
    func elapsedNow() -> Double { elapsed(atHostTime: mach_absolute_time()) }
}

/// Writes a mono Float32 CAF whose position on the timeline follows the recording clock:
/// if the source pauses (e.g. the system tap goes quiet when nothing plays), silence is inserted
/// so the file never drifts relative to the other track.
final class TimelineWriter {
    let sampleRate: Double
    let format: AVAudioFormat
    private let file: AVAudioFile
    private let clock: RecordingClock
    private let queue = DispatchQueue(label: "meetingrecorder.timelinewriter", qos: .userInitiated)
    private let padThreshold: Double
    private let silence: AVAudioPCMBuffer
    private var framesWritten: Int64 = 0
    private var started = false
    private var finished = false
    private(set) var writeErrors = 0
    /// Set up only when a source arrives at a different rate than the track — see `prepared(_:)`.
    private var resampler: AVAudioConverter?
    private var resamplerInput: AVAudioFormat?

    init(url: URL, sampleRate: Double, clock: RecordingClock, padThreshold: Double = 0.15) throws {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let silence = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sampleRate)) else {
            throw NSError(domain: "TimelineWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported sample rate \(sampleRate)"])
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        silence.frameLength = silence.frameCapacity
        silence.floatChannelData?[0].update(repeating: 0, count: Int(silence.frameCapacity))
        self.silence = silence
        self.format = fmt
        self.sampleRate = sampleRate
        self.clock = clock
        self.padThreshold = padThreshold
    }

    /// Seconds of audio on disk so far (including inserted silence).
    var seconds: Double { queue.sync { Double(framesWritten) / sampleRate } }

    /// `hostTime` is when the first frame of `buffer` was captured; pass 0 if unknown.
    /// Safe to call from realtime audio threads: the mixdown copies, then work moves to a serial queue.
    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let mono = prepared(buffer) else { return }
        let start: Double
        if hostTime != 0 {
            start = clock.elapsed(atHostTime: hostTime)
        } else {
            start = clock.elapsedNow() - Double(buffer.frameLength) / buffer.format.sampleRate
        }
        queue.async { [self] in
            guard !finished else { return }
            let expected = Int64((start * sampleRate).rounded())
            let gap = expected - framesWritten
            let threshold: Int64 = started ? Int64(padThreshold * sampleRate) : 0
            if gap > threshold { pad(frames: gap) }
            started = true
            do {
                try file.write(from: mono)
                framesWritten += Int64(mono.frameLength)
            } catch {
                writeErrors += 1
                if writeErrors <= 3 { Log.capture.error("track write failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Pad with silence up to the recording's total length and close the file.
    func finish(totalSeconds: Double) {
        queue.sync {
            let expected = Int64((totalSeconds * sampleRate).rounded())
            let gap = expected - framesWritten
            if gap > 0 { pad(frames: gap) }
            finished = true
        }
    }

    /// Folds a source buffer down to the track's mono format, resampling if the device came back at a
    /// different rate — which is what a restart after a route change (headphones in, say) hands us.
    private func prepared(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sourceRate = buffer.format.sampleRate
        if sourceRate == sampleRate { return AudioMix.mono(buffer, format: format) }
        guard let sourceMono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                             channels: 1, interleaved: false),
              let mono = AudioMix.mono(buffer, format: sourceMono) else { return nil }
        if resamplerInput?.sampleRate != sourceRate {
            resampler = AVAudioConverter(from: sourceMono, to: format)
            resamplerInput = sourceMono
        }
        guard let resampler else { return nil }
        let capacity = AVAudioFrameCount(Double(mono.frameLength) * sampleRate / sourceRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        resampler.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return mono
        }
        if error != nil { return nil }
        return out.frameLength > 0 ? out : nil
    }

    private func pad(frames: Int64) {
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, Int64(silence.frameCapacity)))
            silence.frameLength = n
            do { try file.write(from: silence) } catch { writeErrors += 1; return }
            framesWritten += Int64(n)
            remaining -= Int64(n)
        }
        silence.frameLength = silence.frameCapacity
    }
}
