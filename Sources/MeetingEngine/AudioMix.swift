#if canImport(AVFoundation)
import Foundation
import AVFoundation

public enum AudioMix {
    /// Average all channels into a new mono Float32 buffer (deinterleaved).
    public static func mono(_ src: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
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

    public static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
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
#endif
