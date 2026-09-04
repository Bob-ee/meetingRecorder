import Accelerate
import Foundation

/// The second half of echo cancellation: getting rid of what the least-squares filter could not.
///
/// A linear filter can only remove the part of the echo that is a linear function of the signal sent to
/// the speakers, and on a laptop that stops at about 15 dB — the speaker distorts a little, the two
/// capture clocks drift a fraction of a sample against each other over a long meeting, the room moves.
/// That is plenty when the echo is quiet. It is nowhere near enough here: a built-in microphone hears
/// the built-in speakers at roughly the same level the meeting itself is recorded at, so 15 dB still
/// leaves speech that is louder than a quiet near-end talker, and the transcriber writes it all down
/// under the recorder's name.
///
/// What is left over is not linearly predictable, but it is still *loud where the speakers were loud*,
/// band by band and moment by moment. So the leftovers get attenuated instead of subtracted: in each
/// narrow band, the echo the filter did remove says how much echo was there, a leakage figure measured
/// from the recording itself says what fraction of it survived, and the band is turned down by that
/// much. Bands carrying the near-end voice are left alone, because there the leftover echo is small
/// next to what is actually there — which is what keeps someone talking over the meeting audible.
///
/// Measuring leakage is the part that only works offline. In a call it has to be guessed from the
/// recent past and kept conservative; here the whole meeting is on disk, so each band can be compared
/// against every moment the speakers were loud in it and the quietest quarter taken — those are the
/// moments where nothing but echo was present, which is exactly the ratio wanted.
///
/// Turning the leftovers down is not on its own enough, because the thing that reads this track next
/// does not care how loud it is. Speech recognisers normalise what they are given, so echo attenuated
/// to a whisper is still transcribed — only now it is mangled enough that it no longer matches the
/// other track word for word, which defeats the check downstream that throws repeated words away. So
/// the frames carrying no near-end voice at all are not attenuated but zeroed: silence is the one
/// thing a recogniser cannot make words out of.
enum ResidualEcho {
    /// 32 ms at 16 kHz: long enough to resolve speech formants, short enough to follow syllables.
    static let frameSize = 512
    static var hop: Int { frameSize / 2 }
    /// How often leakage is re-measured, so a meeting whose room changes partway is still followed.
    static let segmentSeconds: Double = 30
    /// Leakage is an average, and echo peaks above it. Subtracting a few times the estimate buys real
    /// quiet in exchange for a little near-end colouration the transcriber does not care about.
    static let overSubtraction: Float = 3
    /// Never take a band below this: a hard zero sounds like — and transcribes like — chopped speech.
    static let floorGain: Float = 0.03
    /// Carrying a little of the previous frame's gain stops bands flickering between open and shut,
    /// which is what turns residual noise into warbling artefacts.
    static let gainSmoothing: Float = 0.5
    /// Below this many loud frames in a band there is nothing to measure leakage from.
    static let minimumMeasurements = 16
    /// How far a frame has to stand above the echo left in it to count as someone talking. Measured on
    /// this recording, echo-only frames sit within a few dB of the estimate and frames with a near-end
    /// voice run tens of dB above it, so 12 dB sits in the gap with room on both sides.
    static let keepMarginDB: Float = 12
    /// Speech does not arrive one frame at a time. Requiring a run before the gate opens throws away the
    /// isolated frames where a burst of echo happened to beat the estimate. ~130 ms.
    static let minimumVoicedRun = 8
    /// Frames of grace either side of near-end speech, ~100 ms, so the gate never bites off the start
    /// of a word or the tail of one.
    static let hangoverFrames = 6

    /// `residual` is the microphone after the linear filter; `echo` is what that filter removed.
    static func suppress(_ residual: [Float], echo: [Float], rate: Double) -> [Float] {
        let total = residual.count
        guard echo.count == total, total >= frameSize, let fft = FFT(size: frameSize) else { return residual }
        defer { fft.destroy() }

        let bins = frameSize / 2 + 1
        let window = analysisWindow(frameSize)
        let framesPerSegment = max(minimumMeasurements * 4, Int(segmentSeconds * rate) / hop)

        var output = [Float](repeating: 0, count: total)
        var weight = [Float](repeating: 0, count: total)
        var carried = [Float](repeating: 1, count: bins)

        var frame = [Float](repeating: 0, count: frameSize)
        var real = [Float](repeating: 0, count: bins)
        var imaginary = [Float](repeating: 0, count: bins)

        var segmentStart = 0
        while segmentStart + frameSize <= total {
            var starts: [Int] = []
            var at = segmentStart
            while at + frameSize <= total, starts.count < framesPerSegment {
                starts.append(at)
                at += hop
            }
            segmentStart = at

            var residualReal = [Float](repeating: 0, count: starts.count * bins)
            var residualImaginary = residualReal
            var residualPower = residualReal
            var echoPower = residualReal

            for (index, start) in starts.enumerated() {
                windowed(residual, at: start, by: window, into: &frame)
                fft.forward(frame, real: &real, imaginary: &imaginary)
                for k in 0..<bins {
                    residualReal[index * bins + k] = real[k]
                    residualImaginary[index * bins + k] = imaginary[k]
                    residualPower[index * bins + k] = real[k] * real[k] + imaginary[k] * imaginary[k]
                }
                windowed(echo, at: start, by: window, into: &frame)
                fft.forward(frame, real: &real, imaginary: &imaginary)
                for k in 0..<bins {
                    echoPower[index * bins + k] = real[k] * real[k] + imaginary[k] * imaginary[k]
                }
            }

            let leak = leakage(residualPower: residualPower, echoPower: echoPower,
                               frames: starts.count, bins: bins)
            let voiced = nearEndFrames(residualPower: residualPower, echoPower: echoPower,
                                       leak: leak, frames: starts.count, bins: bins)

            for (index, start) in starts.enumerated() {
                for k in 0..<bins {
                    var gain: Float = 0
                    if voiced[index] {
                        let here = residualPower[index * bins + k]
                        let echoHere = echoPower[index * bins + k] * leak[k] * overSubtraction
                        gain = here > 1e-20 ? 1 - (min(1, echoHere / here)).squareRoot() : 1
                        gain = max(floorGain, gain)
                        // Smoothing is for the gains inside speech, where flicker between open and shut
                        // is what makes residual noise warble. A frame the gate closed is closed now —
                        // easing into it would just leave the loudest part of the echo audible.
                        gain = gainSmoothing * carried[k] + (1 - gainSmoothing) * gain
                    }
                    carried[k] = gain
                    real[k] = residualReal[index * bins + k] * gain
                    imaginary[k] = residualImaginary[index * bins + k] * gain
                }
                fft.inverse(real: real, imaginary: imaginary, into: &frame)
                for i in 0..<frameSize {
                    output[start + i] += frame[i] * window[i]
                    weight[start + i] += window[i] * window[i]
                }
            }
        }

        // The first and last half-frame are only partly covered by the overlap-add; there the input is
        // kept rather than divided back up by a weight close to zero.
        for i in 0..<total { output[i] = weight[i] > 1e-3 ? output[i] / weight[i] : residual[i] }
        return output
    }

    /// Which frames still hold a near-end voice once the estimated echo is accounted for. Everything
    /// else is echo, room noise, or nothing, and gets silenced outright.
    private static func nearEndFrames(residualPower: [Float], echoPower: [Float], leak: [Float],
                                      frames: Int, bins: Int) -> [Bool] {
        let margin = pow(10, keepMarginDB / 10)
        var loud = [Bool](repeating: false, count: frames)
        for f in 0..<frames {
            var here: Float = 0
            var echoHere: Float = 0
            for k in 0..<bins {
                here += residualPower[f * bins + k]
                echoHere += echoPower[f * bins + k] * leak[k]
            }
            loud[f] = here > echoHere * margin
        }

        var voiced = [Bool](repeating: false, count: frames)
        var f = 0
        while f < frames {
            guard loud[f] else { f += 1; continue }
            var end = f
            while end < frames, loud[end] { end += 1 }
            if end - f >= minimumVoicedRun {
                for n in max(0, f - hangoverFrames)..<min(frames, end + hangoverFrames) { voiced[n] = true }
            }
            f = end
        }
        return voiced
    }

    /// For each band, the fraction of the removed echo's power that the linear filter left behind.
    ///
    /// Taken over the frames where the speakers were loud in that band, and read at the lower quartile:
    /// the near-end talker only ever adds energy, so the quiet quarter of those frames is where the
    /// microphone was hearing echo and nothing else.
    private static func leakage(residualPower: [Float], echoPower: [Float],
                                frames: Int, bins: Int) -> [Float] {
        var leak = [Float](repeating: 0, count: bins)
        guard frames > 0 else { return leak }
        var column = [Float](repeating: 0, count: frames)
        var ratios: [Float] = []
        ratios.reserveCapacity(frames)

        for k in 0..<bins {
            for f in 0..<frames { column[f] = echoPower[f * bins + k] }
            column.sort()
            let loud = max(column[frames * 3 / 5], 1e-16)
            ratios.removeAll(keepingCapacity: true)
            for f in 0..<frames {
                let e = echoPower[f * bins + k]
                if e >= loud { ratios.append(residualPower[f * bins + k] / e) }
            }
            guard ratios.count >= minimumMeasurements else { continue }
            ratios.sort()
            leak[k] = ratios[ratios.count / 4]
        }
        return leak
    }

    /// Root-Hann. Applied on the way in and again on the way out it multiplies up to a Hann window,
    /// which at half-frame overlap adds back to exactly one — so gains of 1 return the signal unchanged.
    private static func analysisWindow(_ size: Int) -> [Float] {
        (0..<size).map { Float((0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))).squareRoot()) }
    }

    private static func windowed(_ signal: [Float], at start: Int, by window: [Float], into frame: inout [Float]) {
        signal.withUnsafeBufferPointer { s in
            window.withUnsafeBufferPointer { w in
                frame.withUnsafeMutableBufferPointer { f in
                    vDSP_vmul(s.baseAddress! + start, 1, w.baseAddress!, 1, f.baseAddress!, 1, vDSP_Length(f.count))
                }
            }
        }
    }
}

/// Real-to-complex FFT over a power-of-two frame, unpacked into `size / 2 + 1` ordinary bins.
/// vDSP's real transform stores DC and Nyquist together in the first slot, which is fiddly to reason
/// about at the call site, so that is undone here.
private struct FFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init?(size: Int) {
        guard size > 1, size & (size - 1) == 0 else { return nil }
        let log2n = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.size = size
        self.log2n = log2n
        self.setup = setup
    }

    func destroy() { vDSP_destroy_fftsetup(setup) }

    func forward(_ samples: [Float], real: inout [Float], imaginary: inout [Float]) {
        let half = size / 2
        var packedReal = [Float](repeating: 0, count: half)
        var packedImaginary = [Float](repeating: 0, count: half)
        packedReal.withUnsafeMutableBufferPointer { rp in
            packedImaginary.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBufferPointer { s in
                    s.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        real[0] = packedReal[0]; imaginary[0] = 0
        real[half] = packedImaginary[0]; imaginary[half] = 0
        for k in 1..<half {
            real[k] = packedReal[k]
            imaginary[k] = packedImaginary[k]
        }
    }

    func inverse(real: [Float], imaginary: [Float], into samples: inout [Float]) {
        let half = size / 2
        var packedReal = [Float](repeating: 0, count: half)
        var packedImaginary = [Float](repeating: 0, count: half)
        packedReal[0] = real[0]
        packedImaginary[0] = real[half]
        for k in 1..<half {
            packedReal[k] = real[k]
            packedImaginary[k] = imaginary[k]
        }
        packedReal.withUnsafeMutableBufferPointer { rp in
            packedImaginary.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                samples.withUnsafeMutableBufferPointer { s in
                    s.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                        vDSP_ztoc(&split, 1, c, 2, vDSP_Length(half))
                    }
                }
            }
        }
        // vDSP's real transform pair comes back scaled by twice the frame length.
        var scale = 1 / Float(2 * size)
        samples.withUnsafeMutableBufferPointer { s in
            vDSP_vsmul(s.baseAddress!, 1, &scale, s.baseAddress!, 1, vDSP_Length(size))
        }
    }
}
