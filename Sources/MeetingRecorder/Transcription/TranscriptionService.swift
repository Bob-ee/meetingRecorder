import Foundation
import FluidAudio

/// On-device transcription: Parakeet TDT (ASR) + offline VBx diarization, all CoreML.
/// The mic track is labeled "You"; remote audio is split into "Speaker 1", "Speaker 2", …
actor TranscriptionService {
    static let shared = TranscriptionService()

    private var asr: AsrManager?
    private var asrVersion: AsrModelVersion?
    private var diarizer: OfflineDiarizerManager?

    static func modelVersion(from setting: String) -> AsrModelVersion {
        setting == "v2" ? .v2 : .v3
    }

    static var modelsDirectory: URL {
        AsrModels.defaultCacheDirectory().deletingLastPathComponent()
    }

    var isReady: Bool { asr != nil && diarizer != nil }

    func prepare(version: AsrModelVersion, status: @escaping @Sendable (String) -> Void) async throws {
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

    func transcribe(micURL: URL?, remoteURL: URL?, userLabel: String,
                    status: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        guard let asr else { throw TranscriptionError.notReady }
        var words: [Word] = []
        var trackNotes: [String] = []

        if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
            status("Transcribing your microphone track…")
            let loaded = try AudioLoader.loadMono16k(micURL)
            Log.pipeline.info("mic track: \(loaded.seconds, privacy: .public)s rms=\(loaded.rms, privacy: .public)")
            trackNotes.append(String(format: "mic %.1fs%@", loaded.seconds, loaded.rms < 0.001 ? " (silent)" : ""))
            let samples = loaded.samples
            if samples.count > 16_000 {
                let timings = try await transcribeWords(samples, asr: asr)
                words += timings.map { Word(text: $0.word, start: $0.startTime, end: $0.endTime, speaker: userLabel) }
            }
        }

        if let remoteURL, FileManager.default.fileExists(atPath: remoteURL.path) {
            status("Transcribing other participants…")
            let loaded = try AudioLoader.loadMono16k(remoteURL)
            Log.pipeline.info("remote track: \(loaded.seconds, privacy: .public)s rms=\(loaded.rms, privacy: .public)")
            trackNotes.append(String(format: "%@ %.1fs%@", remoteURL.lastPathComponent.hasPrefix("import") ? "imported audio" : "system audio", loaded.seconds, loaded.rms < 0.001 ? " (silent)" : ""))
            let samples = loaded.samples
            if samples.count > 16_000 {
                let timings = try await transcribeWords(samples, asr: asr)
                var labels: [String] = Array(repeating: "Speaker 1", count: timings.count)
                if let diarizer, !timings.isEmpty {
                    status("Identifying speakers…")
                    do {
                        let result = try await diarizer.process(audio: samples)
                        labels = Self.assignSpeakers(timings, diarization: result.segments)
                    } catch {
                        Log.pipeline.error("diarization failed, using a single speaker: \(error.localizedDescription, privacy: .public)")
                    }
                }
                for (i, t) in timings.enumerated() {
                    words.append(Word(text: t.word, start: t.startTime, end: t.endTime, speaker: labels[i]))
                }
            }
        }

        words.sort { $0.start < $1.start }
        let segments = Self.utterances(from: words)
        guard !segments.isEmpty else {
            throw TranscriptionError.noSpeech(trackNotes.isEmpty ? "no audio tracks found" : trackNotes.joined(separator: ", "))
        }
        return segments
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

enum TranscriptionError: LocalizedError {
    case notReady
    case noSpeech(String)
    var errorDescription: String? {
        switch self {
        case .notReady: return "Speech models are not loaded"
        case .noSpeech(let detail): return "No speech was detected in the recording (\(detail))"
        }
    }
}
