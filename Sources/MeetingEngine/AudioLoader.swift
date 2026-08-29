#if canImport(AVFoundation)
import Foundation
import AVFoundation
import MeetingCore

/// Loads any audio file AVFoundation can read (CAF/WAV/AIFF/M4A/MP3, any channel count)
/// as 16 kHz mono Float32 samples, streaming so long meetings don't blow up memory.
public enum AudioLoader {
    public static let targetRate: Double = 16_000

    public struct Loaded {
        public var samples: [Float]
        public var seconds: Double { Double(samples.count) / AudioLoader.targetRate }
        public var rms: Float {
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for s in samples { sum += s * s }
            return sqrt(sum / Float(samples.count))
        }
    }

    public static func loadMono16k(_ url: URL) throws -> Loaded {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard file.length > 0, srcFormat.sampleRate > 0 else { return Loaded(samples: []) }

        guard let monoSrc = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcFormat.sampleRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "AudioLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
        }
        let needsResample = srcFormat.sampleRate != targetRate
        let converter = needsResample ? AVAudioConverter(from: monoSrc, to: outFormat) : nil
        if needsResample, converter == nil {
            throw NSError(domain: "AudioLoader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't resample \(srcFormat.sampleRate) Hz audio"])
        }

        let chunk: AVAudioFrameCount = 65_536
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunk) else {
            throw NSError(domain: "AudioLoader", code: 3, userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate audio buffer"])
        }
        let ratio = targetRate / srcFormat.sampleRate
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * ratio) + 1024)

        func appendConverted(_ mono: AVAudioPCMBuffer?, endOfStream: Bool) throws {
            guard let converter else {
                if let mono, let p = mono.floatChannelData?[0] { out.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(mono.frameLength))) }
                return
            }
            let capacity = AVAudioFrameCount(Double(mono?.frameLength ?? 0) * ratio) + 4096
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var delivered = false
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
                if delivered || mono == nil {
                    outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                    return nil
                }
                delivered = true
                outStatus.pointee = .haveData
                return mono
            }
            if let error { throw error }
            if status == .error { throw NSError(domain: "AudioLoader", code: 4, userInfo: [NSLocalizedDescriptionKey: "Resampling failed"]) }
            if let p = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
            }
        }

        while file.framePosition < file.length {
            try file.read(into: readBuf, frameCount: chunk)
            guard readBuf.frameLength > 0 else { break }
            guard let mono = AudioMix.mono(readBuf, format: monoSrc) else { break }
            try appendConverted(mono, endOfStream: false)
        }
        if converter != nil { try appendConverted(nil, endOfStream: true) }
        return Loaded(samples: out)
    }
}
#endif
