import Foundation
import AVFoundation

/// Brings an external recording (phone voice memo, Zoom local recording, a video…) into a meeting folder.
enum AudioImporter {
    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aif", "aiff", "aifc", "caf", "flac", "aac", "mp4", "m4v", "mov", "3gp", "3g2",
        "amr", "opus", "ogg", "oga", "webm", "mkv", "wma", "mp2", "ac3", "m4b", "m4r",
    ]

    static func isAudioFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
        guard !url.lastPathComponent.hasPrefix(".") else { return false }
        return audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Best guess at when the recording happened.
    static func recordingDate(of url: URL) -> Date {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let created = attrs[.creationDate] as? Date
        let modified = attrs[.modificationDate] as? Date
        switch (created, modified) {
        case let (c?, m?): return min(c, m)
        case let (c?, nil): return c
        case let (nil, m?): return m
        default: return Date()
        }
    }

    /// Copies (or moves) `source` into `folder` as `import.<ext>`. Files AVFoundation can't read as audio
    /// (video containers, exotic codecs) get their audio extracted to `import.m4a`.
    /// Returns the staged file's name and duration in seconds.
    static func stage(_ source: URL, into folder: URL, move: Bool) async throws -> (fileName: String, duration: Double) {
        let fm = FileManager.default
        if let file = try? AVAudioFile(forReading: source), file.fileFormat.sampleRate > 0 {
            let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
            let dest = folder.appendingPathComponent("import.\(ext)")
            try? fm.removeItem(at: dest)
            if move { try fm.moveItem(at: source, to: dest) } else { try fm.copyItem(at: source, to: dest) }
            return (dest.lastPathComponent, Double(file.length) / file.fileFormat.sampleRate)
        }

        // Fallback: let AVFoundation demux/decode whatever it can and write AAC.
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw NSError(domain: "AudioImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(source.lastPathComponent) has no audio track"])
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "AudioImporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't convert \(source.lastPathComponent)"])
        }
        let dest = folder.appendingPathComponent("import.m4a")
        try? fm.removeItem(at: dest)
        try await session.export(to: dest, as: .m4a)
        if move { try? fm.removeItem(at: source) }
        return (dest.lastPathComponent, duration)
    }
}
