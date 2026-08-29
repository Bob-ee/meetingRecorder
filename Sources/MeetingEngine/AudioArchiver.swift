#if canImport(AVFoundation)
import Foundation
import AVFoundation
import MeetingCore

/// Converts a raw capture track to mono AAC (~30 MB/hour) and removes the original.
public enum AudioArchiver {
    public static func compressAndReplace(_ url: URL) {
        let dest = url.deletingPathExtension().appendingPathExtension("m4a")
        do {
            try compress(url, to: dest)
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            guard (attrs[.size] as? Int ?? 0) > 0 else { throw NSError(domain: "AudioArchiver", code: 1) }
            try FileManager.default.removeItem(at: url)
            Log.pipeline.info("compressed \(url.lastPathComponent) → \(dest.lastPathComponent)")
        } catch {
            Log.pipeline.error("compression of \(url.lastPathComponent) failed, keeping original: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: dest)
        }
    }

    public static func compress(_ src: URL, to dest: URL) throws {
        let input = try AVAudioFile(forReading: src)
        let srcFormat = input.processingFormat
        let rate = [48_000.0, 44_100.0, 32_000.0, 24_000.0, 22_050.0, 16_000.0].contains(srcFormat.sampleRate) ? srcFormat.sampleRate : 48_000.0
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcFormat.sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "AudioArchiver", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad source format"])
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        try? FileManager.default.removeItem(at: dest)
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let needsResample = rate != srcFormat.sampleRate
        let converter = needsResample ? AVAudioConverter(from: mono, to: output.processingFormat) : nil

        let chunk: AVAudioFrameCount = 65_536
        guard let readBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunk) else { return }
        while input.framePosition < input.length {
            try input.read(into: readBuf, frameCount: chunk)
            guard readBuf.frameLength > 0, let monoBuf = AudioMix.mono(readBuf, format: mono) else { break }
            if let converter {
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: chunk) else { break }
                var delivered = false
                var error: NSError?
                converter.convert(to: outBuf, error: &error) { _, status in
                    if delivered { status.pointee = .noDataNow; return nil }
                    delivered = true; status.pointee = .haveData; return monoBuf
                }
                if let error { throw error }
                if outBuf.frameLength > 0 { try output.write(from: outBuf) }
            } else {
                try output.write(from: monoBuf)
            }
        }
    }
}
#endif
