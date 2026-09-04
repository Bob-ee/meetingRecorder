import Accelerate
import Foundation
import MeetingCore

/// Subtracts the meeting's own audio back out of the microphone track.
///
/// When you run a meeting on speakers, your microphone records everyone twice: once as themselves
/// on the system track, and once as a delayed, room-coloured copy bleeding out of the speakers. The
/// transcriber then hears both and attributes the copy to you, which doubles the transcript and
/// shreds it into fragments as the two versions interleave.
///
/// macOS can strip that in realtime with its voice-processing unit, but only by quieting every other
/// sound on the machine for the whole meeting, and it offers no way to opt out of that. Doing it
/// after the fact avoids the trade entirely, and works better besides: we have the exact signal that
/// went to the speakers, both tracks share a clock, and nothing has to be decided in one pass.
///
/// The estimate is a least-squares solve for the room's impulse response — speaker colouration, the
/// path back to the microphone, the first reflections — which is then subtracted, leaving whatever the
/// mic heard that the speakers did not: you.
///
/// Subtraction alone gets to about 15 dB, which is fine when the echo is quiet and nowhere near enough
/// when it is not: a laptop's own microphone hears its own speakers at roughly the level the meeting
/// itself is recorded at, so what survives is still louder than a near-end talker. `ResidualEcho` takes
/// the second half of the job, using the echo this filter did remove to find and silence what it could
/// not.
///
/// A realtime canceller has to adapt sample by sample and can be pushed off course by loud near-end
/// speech, which matters here because a laptop's mic hears its own speakers at roughly unity gain.
/// Working offline we can instead solve each stretch in one shot from its own statistics: the room
/// response is what best explains the whole block, and your voice, being uncorrelated with the
/// reference, biases that solution toward zero rather than destabilising it.
public enum EchoCanceller {
    public struct Result {
        /// The microphone track with the estimated echo removed.
        public var samples: [Float]
        /// Bulk delay found between the two tracks, in samples at `rate`.
        public var delaySamples: Int
        /// Echo return loss enhancement in dB — how much quieter the track got where only echo was
        /// present. Around 10 dB is a usable improvement; below ~3 dB means the filter found nothing.
        public var erleDB: Float
    }

    /// Filter length in taps. At 16 kHz, 2048 taps covers 128 ms — long enough for a small room's
    /// reverb tail, and wide enough that the filter can absorb the delay wandering as the two capture
    /// paths drift apart over a long meeting.
    public static let defaultTaps = 2048

    /// Below this the solve found no echo path worth having — headphones, most often, where there is
    /// nothing leaking into the microphone in the first place. Leave the track alone rather than spend
    /// quality suppressing a guess.
    public static let minimumUsefulERLE: Float = 3

    public static func removeEcho(from mic: [Float], reference: [Float], rate: Double,
                                  taps: Int = defaultTaps) -> Result {
        guard !mic.isEmpty, !reference.isEmpty else {
            return Result(samples: mic, delaySamples: 0, erleDB: 0)
        }
        let delay = estimateDelay(mic: mic, reference: reference, rate: rate)
        // Sit the window a quarter of its length ahead of the estimate: the filter then spans delays
        // from a little before it to well after, so a slightly wrong estimate costs nothing.
        let aligned = align(reference, by: delay - taps / 4, length: mic.count)
        let (residual, echo) = cancel(mic: mic, reference: aligned, taps: taps, rate: rate)
        let linear = erle(before: mic, after: residual, reference: aligned)
        guard linear >= minimumUsefulERLE else {
            return Result(samples: mic, delaySamples: delay, erleDB: linear)
        }
        // Subtraction gets the predictable part. The rest — speaker distortion, the two capture clocks
        // drifting against each other — is still loud wherever the speakers were loud, so it is turned
        // down band by band instead.
        let suppressed = ResidualEcho.suppress(residual, echo: echo, rate: rate)
        return Result(samples: suppressed, delaySamples: delay,
                      erleDB: erle(before: mic, after: suppressed, reference: aligned))
    }

    // MARK: - Alignment

    /// Finds how far the speaker signal lags behind in the microphone track — sound needs time to
    /// leave the speaker and come back, and the two capture paths buffer differently. Correlating a
    /// few windows and taking the median keeps one noisy stretch from setting the answer.
    static func estimateDelay(mic: [Float], reference: [Float], rate: Double,
                              maxLagSeconds: Double = 0.5) -> Int {
        let maxLag = min(Int(maxLagSeconds * rate), min(mic.count, reference.count) / 2)
        guard maxLag > 0 else { return 0 }
        let window = min(Int(4 * rate), min(mic.count, reference.count) - maxLag)
        guard window > Int(rate) else { return 0 }

        let usable = min(mic.count, reference.count) - window - maxLag
        guard usable > 0 else { return 0 }
        let probes = stride(from: usable / 5, through: max(usable / 5, usable * 4 / 5), by: max(1, usable / 3))

        var found: [Int] = []
        for origin in probes {
            if let lag = bestLag(mic: mic, reference: reference, origin: origin, window: window, maxLag: maxLag) {
                found.append(lag)
            }
        }
        guard !found.isEmpty else { return 0 }
        found.sort()
        return found[found.count / 2]
    }

    private static func bestLag(mic: [Float], reference: [Float], origin: Int, window: Int, maxLag: Int) -> Int? {
        // Skip windows with no real signal — silence correlates with everything.
        var micEnergy: Float = 0
        mic.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + origin, 1, &micEnergy, vDSP_Length(window)) }
        guard micEnergy > 1e-6 else { return nil }

        var best = (lag: 0, score: -Float.greatestFiniteMagnitude)
        mic.withUnsafeBufferPointer { m in
            reference.withUnsafeBufferPointer { r in
                for lag in 0..<maxLag {
                    let refStart = origin - lag
                    guard refStart >= 0 else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(m.baseAddress! + origin, 1, r.baseAddress! + refStart, 1, &dot, vDSP_Length(window))
                    var energy: Float = 0
                    vDSP_svesq(r.baseAddress! + refStart, 1, &energy, vDSP_Length(window))
                    // Normalise so a loud stretch of reference can't outscore a better-aligned quiet one.
                    let score = energy > 1e-6 ? dot / sqrt(energy) : 0
                    if score > best.score { best = (lag, score) }
                }
            }
        }
        return best.score > 0 ? best.lag : nil
    }

    /// Shifts the reference forward by `delay` so reference[n] is what the microphone heard at n.
    private static func align(_ reference: [Float], by delay: Int, length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        for n in max(0, delay)..<length {
            let source = n - delay
            if source >= 0 && source < reference.count { out[n] = reference[source] }
        }
        return out
    }

    // MARK: - Least-squares solve

    /// Blocks are solved independently so the filter can follow the room changing — someone adjusts
    /// the volume, the laptop gets nudged — without one bad stretch contaminating the rest.
    static let blockSeconds: Double = 20

    /// Returns the microphone with the echo taken out, and the echo that was taken out — the second
    /// track is what tells the suppressor where the leftovers are.
    private static func cancel(mic: [Float], reference: [Float], taps: Int,
                               rate: Double) -> (residual: [Float], echo: [Float]) {
        var output = mic
        var echo = [Float](repeating: 0, count: mic.count)
        let blockLength = max(taps * 4, Int(blockSeconds * rate))
        var start = 0
        var lastWeights: [Double]?

        while start < mic.count {
            let end = min(start + blockLength, mic.count)
            defer { start = end }
            guard end - start > taps else { continue }

            // Every sample the solve looks at needs a full filter's worth of reference behind it, which
            // the very start of the recording does not have. The first block is fitted from there on
            // and the filter it finds is applied back across the head.
            let from = max(start, taps)
            let weights = (end - from > taps
                           ? solve(mic: mic, reference: reference, from: from, to: end, taps: taps)
                           : nil) ?? lastWeights
            guard let weights else { continue }
            lastWeights = weights
            apply(weights, mic: mic, reference: reference, from: start, to: end, into: &output, echo: &echo)
        }
        return (output, echo)
    }

    /// Builds the normal equations for this block and solves them. The system is the autocorrelation
    /// of the reference against its cross-correlation with the mic — the classic Wiener-Hopf setup.
    private static func solve(mic: [Float], reference: [Float], from start: Int, to end: Int,
                              taps: Int) -> [Double]? {
        var autocorrelation = [Double](repeating: 0, count: taps)
        var crossCorrelation = [Double](repeating: 0, count: taps)
        let length = end - start

        reference.withUnsafeBufferPointer { ref in
            mic.withUnsafeBufferPointer { m in
                for lag in 0..<taps {
                    guard start - lag >= 0 else { break }
                    // lag 0 is the newest sample; `apply` walks the window oldest-first, so it
                    // reverses this vector to match.
                    let shifted = ref.baseAddress! + start - lag
                    var auto: Float = 0, cross: Float = 0
                    vDSP_dotpr(shifted, 1, ref.baseAddress! + start, 1, &auto, vDSP_Length(length))
                    vDSP_dotpr(shifted, 1, m.baseAddress! + start, 1, &cross, vDSP_Length(length))
                    autocorrelation[lag] = Double(auto)
                    crossCorrelation[lag] = Double(cross)
                }
            }
        }
        // Silence has no echo path to find, and dividing by its energy invents one.
        guard autocorrelation[0] > 1e-4 else { return nil }

        // Ridge term: keeps the solve well-conditioned and stops it fitting near-end speech.
        autocorrelation[0] *= 1.01
        return levinsonSolve(autocorrelation: autocorrelation, rightHandSide: crossCorrelation)
    }

    /// Levinson recursion for a symmetric Toeplitz system. Cholesky would need the full matrix and
    /// cubic time; exploiting the Toeplitz structure makes it quadratic, which is what lets the filter
    /// be long enough to matter. (Golub & Van Loan, algorithm 4.7.2.)
    static func levinsonSolve(autocorrelation r: [Double], rightHandSide b: [Double]) -> [Double]? {
        let n = r.count
        guard n > 0, r[0] != 0, b.count == n else { return nil }
        var x = [Double](repeating: 0, count: n)
        x[0] = b[0] / r[0]
        if n == 1 { return x }

        var y = [Double](repeating: 0, count: n)
        var alpha = -r[1] / r[0]
        var beta = 1.0
        y[0] = alpha

        for k in 0..<(n - 1) {
            beta *= 1 - alpha * alpha
            guard beta != 0 else { return nil }

            var sum = b[k + 1]
            for i in 0...k { sum -= r[k + 1 - i] * x[i] }
            let mu = sum / (beta * r[0])
            for i in 0...k { x[i] += mu * y[k - i] }
            x[k + 1] = mu

            if k < n - 2 {
                var forward = r[k + 2]
                for i in 0...k { forward += r[k + 1 - i] * y[i] }
                alpha = -forward / (beta * r[0])
                var next = y
                for i in 0...k { next[i] = y[i] + alpha * y[k - i] }
                next[k + 1] = alpha
                y = next
            }
        }
        return x
    }

    /// Subtracts the predicted echo, but only if doing so actually made the block quieter — a block
    /// the solve got wrong is left exactly as it was rather than made worse.
    private static func apply(_ weights: [Double], mic: [Float], reference: [Float],
                              from start: Int, to end: Int, into output: inout [Float],
                              echo: inout [Float]) {
        let taps = weights.count
        let filter = weights.map(Float.init).reversed().map { $0 }
        var candidate = [Float](repeating: 0, count: end - start)

        reference.withUnsafeBufferPointer { ref in
            filter.withUnsafeBufferPointer { w in
                for n in start..<end {
                    guard n - taps + 1 >= 0 else { candidate[n - start] = mic[n]; continue }
                    var echo: Float = 0
                    vDSP_dotpr(ref.baseAddress! + n - taps + 1, 1, w.baseAddress!, 1, &echo, vDSP_Length(taps))
                    candidate[n - start] = mic[n] - echo
                }
            }
        }

        var beforeEnergy: Float = 0, afterEnergy: Float = 0
        mic.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + start, 1, &beforeEnergy, vDSP_Length(end - start)) }
        candidate.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress!, 1, &afterEnergy, vDSP_Length(end - start)) }
        guard afterEnergy < beforeEnergy else { return }
        for n in start..<end {
            output[n] = candidate[n - start]
            echo[n] = mic[n] - candidate[n - start]
        }
    }

    // MARK: - Measurement

    /// Compares microphone energy before and after, over the stretches where the speakers were playing
    /// and so echo dominates. Measuring everywhere would dilute the number with your own speech, which
    /// the filter is supposed to leave alone.
    static func erle(before: [Float], after: [Float], reference: [Float]) -> Float {
        let frame = 1600  // 100 ms at 16 kHz
        var referenceEnergies: [Float] = []
        var index = 0
        while index + frame <= reference.count {
            var e: Float = 0
            reference.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + index, 1, &e, vDSP_Length(frame)) }
            referenceEnergies.append(e)
            index += frame
        }
        guard !referenceEnergies.isEmpty else { return 0 }
        let loud = referenceEnergies.sorted()[referenceEnergies.count * 3 / 4]
        guard loud > 1e-9 else { return 0 }

        var beforeSum: Float = 0, afterSum: Float = 0
        for (frameIndex, energy) in referenceEnergies.enumerated() where energy >= loud {
            let start = frameIndex * frame
            guard start + frame <= min(before.count, after.count) else { break }
            var b: Float = 0, a: Float = 0
            before.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + start, 1, &b, vDSP_Length(frame)) }
            after.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + start, 1, &a, vDSP_Length(frame)) }
            beforeSum += b
            afterSum += a
        }
        guard beforeSum > 1e-9, afterSum > 1e-9 else { return 0 }
        return 10 * log10(beforeSum / afterSum)
    }
}
