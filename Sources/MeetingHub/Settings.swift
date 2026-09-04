import Fluent
import Foundation
import MeetingCore
import Vapor

/// Per-workspace settings live in the `settings` table; the summarizer block is encrypted because it holds keys.
enum SettingsStore {
    static let summarizerKey = "summarizer"
    static let asrVersionKey = "asrVersion"

    static func load(workspaceID: UUID, db: Database, secrets: Secrets) async throws -> HubSettings {
        let rows = try await SettingModel.query(on: db).filter(\.$workspace.$id == workspaceID).all()
        var summarizer = SummarizerSettings()
        if let raw = rows.first(where: { $0.key == summarizerKey })?.value,
           let json = try? secrets.open(raw),
           let decoded = try? JSONDecoder().decode(SummarizerSettings.self, from: Data(json.utf8)) {
            summarizer = decoded
        }
        let asr = rows.first(where: { $0.key == asrVersionKey })?.value ?? "v3"
        let owner = try await WorkspaceModel.query(on: db).filter(\.$id == workspaceID).with(\.$owner).first()
        return HubSettings(summarizer: summarizer, asrVersion: asr, userName: owner?.owner.name ?? "Me")
    }

    static func save(_ settings: HubSettings, workspaceID: UUID, db: Database, secrets: Secrets) async throws {
        let json = String(decoding: try JSONEncoder().encode(settings.summarizer), as: UTF8.self)
        try await upsert(key: summarizerKey, value: try secrets.seal(json), workspaceID: workspaceID, db: db)
        try await upsert(key: asrVersionKey, value: settings.asrVersion == "v2" ? "v2" : "v3", workspaceID: workspaceID, db: db)
        let name = settings.userName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let ws = try await WorkspaceModel.query(on: db).filter(\.$id == workspaceID).with(\.$owner).first(),
           ws.owner.name != name {
            ws.owner.name = name
            try await ws.owner.save(on: db)
        }
    }

    private static func upsert(key: String, value: String, workspaceID: UUID, db: Database) async throws {
        if let row = try await SettingModel.query(on: db).filter(\.$workspace.$id == workspaceID).filter(\.$key == key).first() {
            row.value = value
            try await row.save(on: db)
        } else {
            try await SettingModel(workspaceID: workspaceID, key: key, value: value).save(on: db)
        }
    }
}

/// Plain Markdown/JSON copy of every meeting, laid out exactly like the Mac app's local folder,
/// so the hub's data is readable without the hub (and easy to back up or point Claude at).
struct ExportMirror {
    let root: URL
    private let fm = FileManager.default

    func projectDir(workspace: String, project: String) -> URL {
        root.appendingPathComponent(Fmt.sanitizeFilename(workspace), isDirectory: true)
            .appendingPathComponent(Fmt.sanitizeFilename(project), isDirectory: true)
    }

    func writeProject(workspace: String, project: ProjectModel) {
        let dir = projectDir(workspace: workspace, project: project.name)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try jsonEncoder.encode(project.dto).write(to: dir.appendingPathComponent("project.json"), options: .atomic)
            try project.context.write(to: dir.appendingPathComponent("CONTEXT.md"), atomically: true, encoding: .utf8)
            try project.learnedContext.write(to: dir.appendingPathComponent("LEARNED.md"), atomically: true, encoding: .utf8)
        } catch {
            Log.hub.error("export mirror (project \(project.name)): \(error.localizedDescription)")
        }
    }

    func write(workspace: String, project: ProjectModel, meeting: Meeting, transcript: [TranscriptSegment],
               summaryMarkdown: String?, notes: String) {
        let pdir = projectDir(workspace: workspace, project: project.name)
        do {
            try fm.createDirectory(at: pdir, withIntermediateDirectories: true)
            // Replace whatever folder currently holds this meeting (its title may have changed).
            for old in existingFolders(for: meeting.id, in: pdir) { try? fm.removeItem(at: old) }
            var dir = pdir.appendingPathComponent("\(Fmt.folderStamp.string(from: meeting.startedAt)) \(Fmt.sanitizeFilename(meeting.title))", isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: dir.path) {
                dir = pdir.appendingPathComponent("\(Fmt.folderStamp.string(from: meeting.startedAt)) \(Fmt.sanitizeFilename(meeting.title)) \(n)", isDirectory: true)
                n += 1
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try jsonEncoder.encode(meeting).write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
            if !transcript.isEmpty {
                try jsonEncoder.encode(transcript).write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
                try MeetingDocuments.transcriptMarkdown(transcript, meeting: meeting)
                    .write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            }
            if let summaryMarkdown {
                try summaryMarkdown.write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            }
            if !notes.isEmpty {
                try notes.write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
            }
        } catch {
            Log.hub.error("export mirror (\(meeting.title)): \(error.localizedDescription)")
        }
    }

    func remove(meetingID: UUID, workspace: String, projectName: String) {
        let pdir = projectDir(workspace: workspace, project: projectName)
        for old in existingFolders(for: meetingID, in: pdir) { try? fm.removeItem(at: old) }
    }

    private func existingFolders(for id: UUID, in pdir: URL) -> [URL] {
        let dirs = (try? fm.contentsOfDirectory(at: pdir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return dirs.filter { dir in
            guard dir.hasDirectoryPath, let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
                  let m = try? jsonDecoder.decode(Meeting.self, from: data) else { return false }
            return m.id == id
        }
    }
}
