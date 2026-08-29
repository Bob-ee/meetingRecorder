import Foundation
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

enum AudioMix {
    /// Average all channels into a new mono Float32 buffer (deinterleaved).
    static func mono(_ src: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(src.frameLength)
        guard frames > 0, src.format.commonFormat == .pcmFormatFloat32,
              let srcData = src.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        let channels = Int(src.format.channelCount)
        if channels == 1 {
            dst.update(from: srcData[0], count: frames)
            return out
        }
        let scale = 1 / Float(channels)
        if src.format.isInterleaved {
            let p = srcData[0]
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += p[i * channels + c] }
                dst[i] = s * scale
            }
        } else {
            dst.update(repeating: 0, count: frames)
            for c in 0..<channels {
                let p = srcData[c]
                for i in 0..<frames { dst[i] += p[i] * scale }
            }
        }
        return out
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        if buffer.format.isInterleaved {
            let p = data[0]
            for i in 0..<(frames * channels) { sum += p[i] * p[i] }
        } else {
            for c in 0..<channels {
                let p = data[c]
                for i in 0..<frames { sum += p[i] * p[i] }
            }
        }
        return sqrt(sum / Float(frames * channels))
    }
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
        guard let mono = AudioMix.mono(buffer, format: format) else { return }
        let start: Double
        if hostTime != 0 {
            start = clock.elapsed(atHostTime: hostTime)
        } else {
            start = clock.elapsedNow() - Double(buffer.frameLength) / sampleRate
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
                if writeErrors <= 3 { Log.capture.error("track write failed: \(error.localizedDescription, privacy: .public)") }
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
