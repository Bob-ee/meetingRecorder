import Crypto
import Fluent
import Foundation
import MeetingCore
import NIOCore
import Vapor

func uploadRoutes(_ r: RoutesBuilder) {
    /// `PUT /meetings/:id/audio/:kind` with the raw file as the body. Streams straight to disk; nothing is buffered.
    /// Optional headers: `X-File-Name` (keeps the extension), `X-Content-SHA256` (verified before the file is accepted).
    r.on(.PUT, "meetings", ":id", "audio", ":kind", body: .stream) { req -> AudioTrackInfo in
        let p = try req.principal
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        guard let kindRaw = req.parameters.get("kind"), let kind = AudioTrackKind(rawValue: kindRaw) else {
            throw Abort(.badRequest, reason: "kind must be mic, system or import")
        }
        let paths = req.application.hubPaths
        let dir = paths.audioDir(workspace: p.workspaceID, meeting: meeting.id!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let requestedName = req.headers.first(name: HubAPI.fileNameHeader) ?? ""
        var ext = URL(fileURLWithPath: requestedName).pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 || ext.contains("/") { ext = "m4a" }
        let fileName = "\(kind.rawValue).\(ext)"
        let final = dir.appendingPathComponent(fileName)
        let tmp = paths.tmp.appendingPathComponent("\(meeting.id!.uuidString)-\(kind.rawValue)-\(UUID().uuidString).part")

        let fileio = req.application.fileio
        let handle = try await fileio.openFile(path: tmp.path, mode: .write, flags: .allowFileCreation(posixMode: 0o600), eventLoop: req.eventLoop).get()
        var hasher = SHA256()
        var offset: Int64 = 0
        do {
            for try await buffer in req.body {
                try await fileio.write(fileHandle: handle, toOffset: offset, buffer: buffer, eventLoop: req.eventLoop).get()
                buffer.withUnsafeReadableBytes { hasher.update(bufferPointer: $0) }
                offset += Int64(buffer.readableBytes)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = req.headers.first(name: HubAPI.checksumHeader)?.lowercased(), !expected.isEmpty, expected != digest {
            try? FileManager.default.removeItem(at: tmp)
            throw Abort(.badRequest, reason: "checksum mismatch — upload again")
        }
        guard offset > 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw Abort(.badRequest, reason: "empty upload")
        }
        // Replace any earlier file of this kind (a retry, or a different extension).
        if let old = try await AudioFileModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).filter(\.$kind == kind.rawValue).first() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(old.fileName))
            try await old.delete(on: req.db)
        }
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)

        let row = AudioFileModel(meetingID: meeting.id!, kind: kind, fileName: fileName, byteSize: Int(offset), sha256: digest)
        try await row.save(on: req.db)
        req.logger.info("received \(fileName) (\(offset) bytes) for “\(meeting.title)”")
        return row.dto
    }

    r.get("meetings", ":id", "audio", ":kind") { req -> Response in
        let p = try req.principal
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        guard let kindRaw = req.parameters.get("kind"), let kind = AudioTrackKind(rawValue: kindRaw) else {
            throw Abort(.badRequest, reason: "kind must be mic, system or import")
        }
        guard let row = try await AudioFileModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).filter(\.$kind == kind.rawValue).first() else {
            throw Abort(.notFound, reason: "no \(kind.rawValue) audio for this meeting")
        }
        let url = req.application.hubPaths.audioDir(workspace: p.workspaceID, meeting: meeting.id!).appendingPathComponent(row.fileName)
        return try await req.fileio.asyncStreamFile(at: url.path)
    }

    r.get("meetings", ":id", "audio") { req -> [AudioTrackInfo] in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        return try await AudioFileModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).all().map(\.dto)
    }
}
