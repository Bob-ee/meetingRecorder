import Crypto
import Fluent
import Foundation
import MeetingCore
import NIOCore
import Vapor

func uploadRoutes(_ r: RoutesBuilder) {
    /// `PUT /meetings/:id/audio/:kind` with the raw file as the body. Streams straight to disk; nothing is buffered.
    /// Optional headers: `X-File-Name` (keeps the extension), `X-Content-SHA256` (verified before the file is accepted).
    ///
    /// `X-Meeting` and `X-Process` let one request do the whole job — create the meeting, store the audio, queue
    /// the work. A phone hands its upload to the system and may never get to run a second request, so a
    /// recording must not depend on one.
    r.on(.PUT, "meetings", ":id", "audio", ":kind", body: .stream) { req -> AudioTrackInfo in
        let p = try req.principal
        let meetingID = try HubQueries.uuid(req, "id")
        let meeting: MeetingModel
        if let header = req.headers.first(name: HubAPI.meetingHeader) {
            meeting = try await HubQueries.createMeeting(req, try newMeeting(from: header, id: meetingID, req))
        } else {
            meeting = try await HubQueries.meeting(req, id: meetingID)
        }
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
        if let header = req.headers.first(name: HubAPI.processHeader) {
            let steps = header.split(separator: ",").compactMap { JobStep(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            if !steps.isEmpty { _ = try await HubQueries.enqueue(req, meeting, steps: steps) }
        }
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

/// The meeting an upload describes in its `X-Meeting` header. A recording is never turned away over its
/// project: if that one is gone (or was made on the device and hasn't been synced yet) it lands in the Inbox,
/// and the device's next sync moves it.
private func newMeeting(from header: String, id: UUID, _ req: Request) async throws -> CreateMeetingRequest {
    guard let data = Data(base64Encoded: header), var body = try? jsonDecoder.decode(CreateMeetingRequest.self, from: data) else {
        throw Abort(.badRequest, reason: "\(HubAPI.meetingHeader) must be a base64 CreateMeetingRequest")
    }
    body.id = id
    let workspaceID = try req.principal.workspaceID
    let projects = try await ProjectModel.query(on: req.db).filter(\.$workspace.$id == workspaceID).sort(\.$createdAt).all()
    if !projects.contains(where: { $0.id == body.projectID }) {
        guard let fallback = projects.first(where: { $0.name == "Inbox" }) ?? projects.first else {
            throw Abort(.notFound, reason: "no project to put this recording in")
        }
        body.projectID = try fallback.requireID()
    }
    return body
}
