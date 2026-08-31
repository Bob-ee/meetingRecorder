import Foundation
import MeetingCore

#if canImport(FluidAudio)
import FluidAudio

/// On-device transcription: Parakeet TDT (ASR) + offline VBx diarization, all CoreML.
/// The mic track is labeled with the recorder's name; remote audio is split into "Speaker 1", "Speaker 2", …
/// Models are heavy, so there is one shared instance per process.
public actor TranscriptionService: Transcriber {
    public static let shared = TranscriptionService()

    private var asr: AsrManager?
    private var asrVersion: AsrModelVersion?
    private var diarizer: OfflineDiarizerManager?
    private var wantedVersion: AsrModelVersion = .v3

    public static func modelVersion(from setting: String) -> AsrModelVersion {
        setting == "v2" ? .v2 : .v3
    }

    public static var modelsDirectory: URL {
        AsrModels.defaultCacheDirectory().deletingLastPathComponent()
    }

    public var isReady: Bool { asr != nil && diarizer != nil }

    /// "v3" (default, multilingual) or "v2" (English-only, slightly smaller).
    public func setModelVersion(_ setting: String) { wantedVersion = Self.modelVersion(from: setting) }

    public func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        try await prepare(version: wantedVersion, status: status)
    }

    public func prepare(version: AsrModelVersion, status: @escaping @Sendable (String) -> Void) async throws {
        if asr == nil || asrVersion != version {
            status("Loading speech model (downloads ~600 MB on first run)…")
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
            asrVersion = version
        }
        if diarizer == nil {
            status("Loading speaker model…")
            let d = OfflineDiarizerManager(config: .default)
            try await d.prepareModels()
            diarizer = d
        }
    }

    struct Word {
        var text: String
        var start: Double
        var end: Double
        var speaker: String
    }

    public func transcribe(micURL: URL?, remoteURL: URL?, userLabel: String,
                           status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        guard let asr else { throw TranscriptionError.notReady }
        var micWords: [Word] = []
        var remoteWords: [Word] = []
        var trackNotes: [String] = []

        // Both tracks are loaded up front so the microphone can have the meeting's own audio
        // subtracted out of it before anything is transcribed.
        var micSamples: [Float] = []
        var remoteSamples: [Float] = []

        if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
            let loaded = try AudioLoader.loadMono16k(micURL)
            Log.pipeline.info("mic track: \(loaded.seconds)s rms=\(loaded.rms)")
            trackNotes.append(String(format: "mic %.1fs%@", loaded.seconds, loaded.rms < 0.001 ? " (silent)" : ""))
            micSamples = loaded.samples
        }
        if let remoteURL, FileManager.default.fileExists(atPath: remoteURL.path) {
            let loaded = try AudioLoader.loadMono16k(remoteURL)
            Log.pipeline.info("remote track: \(loaded.seconds)s rms=\(loaded.rms)")
            trackNotes.append(String(format: "%@ %.1fs%@", remoteURL.lastPathComponent.hasPrefix("import") ? "imported audio" : "system audio", loaded.seconds, loaded.rms < 0.001 ? " (silent)" : ""))
            remoteSamples = loaded.samples
        }

        if micSamples.count > 16_000, remoteSamples.count > 16_000 {
            status("Removing speaker echo from your microphone…")
            let cancelled = EchoCanceller.removeEcho(from: micSamples, reference: remoteSamples,
                                                     rate: AudioLoader.targetRate)
            Log.pipeline.info("echo cancellation: delay \(cancelled.delaySamples) samples, ERLE \(cancelled.erleDB) dB")
            // Below a few dB the solve found no echo path worth subtracting — usually headphones, where
            // there is nothing to cancel. Keep the original rather than spend quality on a guess.
            if cancelled.erleDB >= 3 {
                micSamples = cancelled.samples
                trackNotes.append(String(format: "echo -%.0f dB", cancelled.erleDB))
            }
        }

        if micSamples.count > 16_000 {
            status("Transcribing your microphone track…")
            let timings = try await transcribeWords(micSamples, asr: asr)
            micWords = timings.map { Word(text: $0.word, start: $0.startTime, end: $0.endTime, speaker: userLabel) }
        }

        do {
            status("Transcribing other participants…")
            let samples = remoteSamples
            if samples.count > 16_000 {
                let timings = try await transcribeWords(samples, asr: asr)
                var labels: [String] = Array(repeating: "Speaker 1", count: timings.count)
                if let diarizer, !timings.isEmpty {
                    status("Identifying speakers…")
                    do {
                        let result = try await diarizer.process(audio: samples)
                        labels = Self.assignSpeakers(timings, diarization: result.segments)
                    } catch {
                        Log.pipeline.error("diarization failed, using a single speaker: \(error.localizedDescription)")
                    }
                }
                for (i, t) in timings.enumerated() {
                    remoteWords.append(Word(text: t.word, start: t.startTime, end: t.endTime, speaker: labels[i]))
                }
            }
        }

        let keptMic = Self.removingEcho(from: micWords, matching: remoteWords)
        if keptMic.count < micWords.count {
            Log.pipeline.info("echo filter: dropped \(micWords.count - keptMic.count) of \(micWords.count) mic words that repeated the other track")
        }
        var words = keptMic + remoteWords
        words.sort { $0.start < $1.start }
        let segments = Self.utterances(from: words)
        guard !segments.isEmpty else {
            throw TranscriptionError.noSpeech(trackNotes.isEmpty ? "no audio tracks found" : trackNotes.joined(separator: ", "))
        }
        return segments
    }

    /// Your speakers bleed into your microphone, so everyone else gets transcribed twice — once on
    /// the system track where they belong, and once on the mic track wearing your name. Apple's
    /// voice-processing unit strips that in realtime, but it ducks every other sound on the machine
    /// while it runs and offers no way to turn that off, so we do it here instead. Both tracks share
    /// a clock, which is what makes this possible: mic words that repeat what the system track heard
    /// at the same moment are echo, not you.
    ///
    /// Matched in runs rather than word by word — you and a remote speaker both saying "yeah" at the
    /// same instant is a coincidence worth keeping; four words in a row lining up is not.
    static func removingEcho(from micWords: [Word], matching remoteWords: [Word],
                             tolerance: Double = 0.6, minimumRun: Int = 3) -> [Word] {
        guard !micWords.isEmpty, !remoteWords.isEmpty else { return micWords }

        // Bucket the remote words by second so each mic word costs a dictionary hit, not a scan.
        var buckets: [Int: [Word]] = [:]
        for w in remoteWords {
            let lo = Int((w.start - tolerance).rounded(.down))
            let hi = Int((w.end + tolerance).rounded(.down))
            for second in lo...max(lo, hi) { buckets[second, default: []].append(w) }
        }

        let echoed = micWords.map { mic -> Bool in
            let key = normalized(mic.text)
            guard !key.isEmpty, let candidates = buckets[Int(mic.start.rounded(.down))] else { return false }
            return candidates.contains {
                normalized($0.text) == key && mic.start >= $0.start - tolerance && mic.start <= $0.end + tolerance
            }
        }

        var keep = [Bool](repeating: true, count: micWords.count)
        var i = 0
        while i < echoed.count {
            guard echoed[i] else { i += 1; continue }
            var j = i
            while j < echoed.count, echoed[j] { j += 1 }
            if j - i >= minimumRun { for k in i..<j { keep[k] = false } }
            i = j
        }
        return zip(micWords, keep).filter(\.1).map(\.0)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func transcribeWords(_ samples: [Float], asr: AsrManager) async throws -> [WordTiming] {
        let layers = await asr.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await asr.transcribe(samples, decoderState: &state)
        if let timings = result.tokenTimings, !timings.isEmpty {
            return buildWordTimings(from: timings)
                .map { WordTiming(word: $0.word.trimmingCharacters(in: .whitespaces), startTime: $0.startTime, endTime: $0.endTime) }
                .filter { !$0.word.isEmpty }
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        // No timings available: spread words evenly across the audio so grouping still works.
        let parts = text.split(separator: " ").map(String.init)
        let total = Double(samples.count) / 16_000
        let step = total / Double(max(parts.count, 1))
        return parts.enumerated().map { i, w in
            WordTiming(word: w, startTime: Double(i) * step, endTime: Double(i + 1) * step)
        }
    }

    /// Map each word to the diarization speaker whose segment covers it (or is nearest).
    /// Speaker ids are renumbered in order of first appearance.
    static func assignSpeakers(_ words: [WordTiming], diarization: [TimedSpeakerSegment]) -> [String] {
        let segs = diarization.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var rawLabels: [String?] = []
        for w in words {
            let mid = (w.startTime + w.endTime) / 2
            var best: (id: String, distance: Double)?
            for s in segs {
                let start = Double(s.startTimeSeconds), end = Double(s.endTimeSeconds)
                let d: Double = mid < start ? start - mid : (mid > end ? mid - end : 0)
                if best == nil || d < best!.distance { best = (s.speakerId, d) }
                if d == 0 { break }
            }
            rawLabels.append((best != nil && best!.distance <= 1.5) ? best!.id : nil)
        }
        // Fill gaps with the previous (or next) known speaker.
        var last: String? = nil
        for i in rawLabels.indices {
            if rawLabels[i] == nil { rawLabels[i] = last } else { last = rawLabels[i] }
        }
        var next: String? = nil
        for i in rawLabels.indices.reversed() {
            if rawLabels[i] == nil { rawLabels[i] = next } else { next = rawLabels[i] }
        }
        var numbering: [String: Int] = [:]
        return rawLabels.map { raw in
            let key = raw ?? "?"
            if numbering[key] == nil { numbering[key] = numbering.count + 1 }
            return "Speaker \(numbering[key]!)"
        }
    }

    /// Group words into readable utterances split on speaker change, silence, or sentence ends.
    static func utterances(from words: [Word]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var speaker = "", start = 0.0, end = 0.0
        var buffer: [String] = []

        func flush() {
            let text = buffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append(TranscriptSegment(speaker: speaker, start: start, end: end, text: text)) }
            buffer = []
        }

        for w in words {
            if buffer.isEmpty {
                speaker = w.speaker; start = w.start; end = w.end; buffer = [w.text]
                continue
            }
            let gap = w.start - end
            let endsSentence = buffer.last.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") } ?? false
            let length = w.end - start
            let split = w.speaker != speaker
                || gap > 1.2
                || (endsSentence && gap > 0.45)
                || (endsSentence && length > 35)
                || length > 75
            if split {
                flush()
                speaker = w.speaker; start = w.start; end = w.end; buffer = [w.text]
            } else {
                end = max(end, w.end)
                buffer.append(w.text)
            }
        }
        flush()
        return result
    }
}

#else

/// Placeholder where CoreML models can't run (Linux). A cloud transcription provider will fill this slot.
public actor TranscriptionService: Transcriber {
    public static let shared = TranscriptionService()
    public var isReady: Bool { false }
    public func setModelVersion(_ setting: String) {}
    public func prepare(status: @escaping @Sendable (String) -> Void) async throws {
        throw TranscriptionError.unavailable("on-device speech models need macOS")
    }
    public func transcribe(micURL: URL?, remoteURL: URL?, userLabel: String,
                           status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        throw TranscriptionError.unavailable("on-device speech models need macOS")
    }
}

#endif
