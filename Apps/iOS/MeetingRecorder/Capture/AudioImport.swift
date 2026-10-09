import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Brings a recording made elsewhere (Voice Memos, a call recorder, a file from AirDrop) into the app.
enum AudioImport {
    struct Staged {
        let file: URL
        let originalName: String
        let recordedAt: Date
        let duration: TimeInterval
    }

    static let contentTypes: [UTType] = [.audio, .mpeg4Movie, .quickTimeMovie]

    /// Copy `source` into `directory` under `id`, and read off what the meeting needs to know about it.
    static func stage(_ source: URL, as id: UUID, in directory: URL) async throws -> Staged {
        // Files handed over by the share sheet or the file picker are only readable inside this bracket.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let file = directory.appendingPathComponent("\(id.uuidString).\(ext)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: file)
        do {
            let duration = try await AVURLAsset(url: file).load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw ImportError.notAudio }
            let created = try? source.resourceValues(forKeys: [.creationDateKey]).creationDate
            return Staged(file: file, originalName: source.lastPathComponent, recordedAt: created ?? Date(), duration: duration)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    enum ImportError: LocalizedError {
        case notAudio
        var errorDescription: String? { "it doesn't contain any audio this device can read" }
    }
}
