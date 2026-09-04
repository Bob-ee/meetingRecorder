import Fluent
import Foundation
import MeetingCore
import MeetingEngine
import Vapor

// Wire types come from MeetingCore; this is what lets Vapor encode/decode them.
extension Project: Content {}
extension Meeting: Content {}
extension ActionItem: Content {}
extension TranscriptSegment: Content {}
extension HubInfo: Content {}
extension WhoAmI: Content {}
extension ProjectDetail: Content {}
extension CreateProjectRequest: Content {}
extension PatchProjectRequest: Content {}
extension CreateMeetingRequest: Content {}
extension PatchMeetingRequest: Content {}
extension MeetingDetail: Content {}
extension AudioTrackInfo: Content {}
extension NewActionItemRequest: Content {}
extension PatchActionItemRequest: Content {}
extension AdviceResponse: Content {}
extension JobInfo: Content {}
extension ProcessRequest: Content {}
extension HubSettings: Content {}
extension Capabilities: Content {}
extension TestResult: Content {}
extension PushSummaryRequest: Content {}

func routes(_ app: Application) throws {
    let api = app.grouped("api", "v1")

    api.get("health") { req -> HubInfo in
        req.application.hubInfo.info
    }

    let auth = api.grouped(TokenAuthenticator(), Principal.guardMiddleware())

    auth.get("me") { req -> WhoAmI in
        let p = try req.principal
        return WhoAmI(user: p.user.dto, workspace: p.workspace.dto, device: p.token.name, hub: req.application.hubInfo.info)
    }

    auth.get("capabilities") { req -> Capabilities in
        let info = req.application.hubInfo.info
        return Capabilities(providers: ProviderDescription.all,
                            transcriptionEngines: info.localTranscription ? ["local"] : [],
                            hub: info)
    }

    projectRoutes(auth)
    meetingRoutes(auth)
    actionItemRoutes(auth)
    uploadRoutes(auth)
    settingsRoutes(auth)
    eventRoutes(auth)
}

// MARK: - Shared lookups

enum HubQueries {
    static func project(_ req: Request, id: UUID) async throws -> ProjectModel {
        let p = try req.principal
        guard let project = try await ProjectModel.query(on: req.db)
            .filter(\.$id == id).filter(\.$workspace.$id == p.workspaceID).first() else {
            throw Abort(.notFound, reason: "no such project")
        }
        return project
    }

    static func meeting(_ req: Request, id: UUID) async throws -> MeetingModel {
        let p = try req.principal
        guard let meeting = try await MeetingModel.query(on: req.db)
            .filter(\.$id == id).filter(\.$workspace.$id == p.workspaceID)
            .with(\.$actionItems).with(\.$project).first() else {
            throw Abort(.notFound, reason: "no such meeting")
        }
        return meeting
    }

    static func detail(_ req: Request, _ meeting: MeetingModel) async throws -> MeetingDetail {
        let id = meeting.id!
        let transcript = try await TranscriptModel.query(on: req.db).filter(\.$meeting.$id == id).first()?.segments ?? []
        let summary = try await SummaryModel.query(on: req.db).filter(\.$meeting.$id == id).first()
        let audio = try await AudioFileModel.query(on: req.db).filter(\.$meeting.$id == id).all().map(\.dto)
        let job = try await JobModel.query(on: req.db).filter(\.$meeting.$id == id).sort(\.$createdAt, .descending).first()
        return MeetingDetail(meeting: meeting.dto(), projectName: meeting.project.name, transcript: transcript,
                             summaryMarkdown: summary?.markdown, notes: meeting.notes, audio: audio, job: job?.dto)
    }

    /// ISO-8601 (with or without fractional seconds) or seconds since 1970.
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        if let secs = Double(raw) { return Date(timeIntervalSince1970: secs) }
        return nil
    }

    static func uuid(_ req: Request, _ name: String) throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw Abort(.badRequest, reason: "bad \(name)") }
        return id
    }

    /// The project's still-open action items, numbered for a prompt and leaving out one meeting's own, plus a
    /// lookup of every item in the project so carry-forward can edit the ones a later meeting changed.
    static func projectItems(db: Database, projectID: UUID, excluding meetingID: UUID)
        async throws -> (open: [OpenProjectItem], byID: [UUID: ActionItem]) {
        let siblings = try await MeetingModel.query(on: db).filter(\.$project.$id == projectID)
            .with(\.$actionItems).sort(\.$startedAt, .descending).all()
        let dtos = siblings.map { $0.dto() }
        var byID: [UUID: ActionItem] = [:]
        for m in dtos { for item in m.actionItems { byID[item.id] = item } }
        return (ActionItems.openProjectItems(in: dtos, excluding: meetingID), byID)
    }

    static func broadcastMeeting(_ req: Request, _ meeting: MeetingModel) {
        req.application.eventBus.post(HubEvent(kind: .meetingUpdated, meetingID: meeting.id, projectID: meeting.$project.id))
        let runner = req.application.jobRunner
        Task { await runner.mirror(meeting) }
    }

    static func markdown(_ text: String, fileName: String) -> Response {
        let res = Response(status: .ok, body: .init(string: text))
        res.headers.replaceOrAdd(name: .contentType, value: "text/markdown; charset=utf-8")
        res.headers.replaceOrAdd(name: .contentDisposition, value: "inline; filename=\"\(fileName)\"")
        return res
    }
}

// MARK: - Projects

func projectRoutes(_ r: RoutesBuilder) {
    r.get("projects") { req -> [ProjectDetail] in
        let p = try req.principal
        let projects = try await ProjectModel.query(on: req.db).filter(\.$workspace.$id == p.workspaceID).with(\.$meetings).all()
        return projects
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { ProjectDetail(project: $0.dto, context: $0.context, learnedContext: $0.learnedContext,
                                 meetingCount: $0.meetings.count) }
    }

    r.post("projects") { req -> ProjectDetail in
        let p = try req.principal
        let body = try req.content.decode(CreateProjectRequest.self)
        let name = body.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw Abort(.badRequest, reason: "project name is empty") }
        if let id = body.id, let existing = try await ProjectModel.query(on: req.db).filter(\.$id == id).filter(\.$workspace.$id == p.workspaceID).first() {
            return ProjectDetail(project: existing.dto, context: existing.context,
                                 learnedContext: existing.learnedContext, meetingCount: 0)
        }
        let project = ProjectModel(id: body.id, workspaceID: p.workspaceID, name: name, context: body.context ?? "")
        project.learnedContext = body.learnedContext ?? ""
        try await project.save(on: req.db)
        ExportMirror(root: req.application.hubPaths.export).writeProject(workspace: p.workspace.name, project: project)
        req.application.eventBus.post(HubEvent(kind: .projectUpdated, projectID: project.id))
        return ProjectDetail(project: project.dto, context: project.context,
                             learnedContext: project.learnedContext, meetingCount: 0)
    }

    r.get("projects", ":id") { req -> ProjectDetail in
        let project = try await HubQueries.project(req, id: HubQueries.uuid(req, "id"))
        let count = try await MeetingModel.query(on: req.db).filter(\.$project.$id == project.id!).count()
        return ProjectDetail(project: project.dto, context: project.context,
                             learnedContext: project.learnedContext, meetingCount: count)
    }

    r.patch("projects", ":id") { req -> ProjectDetail in
        let p = try req.principal
        let project = try await HubQueries.project(req, id: HubQueries.uuid(req, "id"))
        let body = try req.content.decode(PatchProjectRequest.self)
        let oldName = project.name
        if let name = body.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { project.name = name }
        if let context = body.context { project.context = context }
        if let learned = body.learnedContext { project.learnedContext = learned }
        try await project.save(on: req.db)
        let mirror = ExportMirror(root: req.application.hubPaths.export)
        if oldName != project.name {
            let old = mirror.projectDir(workspace: p.workspace.name, project: oldName)
            let new = mirror.projectDir(workspace: p.workspace.name, project: project.name)
            if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: new.path) {
                try? FileManager.default.moveItem(at: old, to: new)
            }
        }
        mirror.writeProject(workspace: p.workspace.name, project: project)
        req.application.eventBus.post(HubEvent(kind: .projectUpdated, projectID: project.id))
        let count = try await MeetingModel.query(on: req.db).filter(\.$project.$id == project.id!).count()
        return ProjectDetail(project: project.dto, context: project.context,
                             learnedContext: project.learnedContext, meetingCount: count)
    }

    // Re-derive the learned note from the project's most recent summarized meeting, on request.
    r.post("projects", ":id", "context", "refresh") { req -> ProjectDetail in
        let pr = try req.principal
        let project = try await HubQueries.project(req, id: HubQueries.uuid(req, "id"))
        let settings = try await SettingsStore.load(workspaceID: pr.workspaceID, db: req.db, secrets: req.application.secrets)
        let summarizer = try SummarizerFactory.make(settings.summarizer)
        let meetings = try await MeetingModel.query(on: req.db).filter(\.$project.$id == project.id!)
            .with(\.$actionItems).sort(\.$startedAt, .descending).all()
        var source: (Meeting, String)?
        for m in meetings {
            if let summary = try await SummaryModel.query(on: req.db).filter(\.$meeting.$id == m.id!).first() {
                source = (m.dto(), summary.markdown)
                break
            }
        }
        guard let (meeting, markdown) = source else {
            throw Abort(.badRequest, reason: "no summarized meeting in this project to work from yet")
        }
        let update = try await summarizer.updateContext(ContextUpdateRequest(
            projectName: project.name, userContext: project.context, learnedContext: project.learnedContext,
            meeting: meeting, summaryMarkdown: markdown))
        if let update {
            let text = update.context.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != project.learnedContext {
                project.learnedContext = text
                try await project.save(on: req.db)
                ExportMirror(root: req.application.hubPaths.export).writeProject(workspace: pr.workspace.name, project: project)
                req.application.eventBus.post(HubEvent(kind: .projectUpdated, projectID: project.id))
            }
        }
        let count = try await MeetingModel.query(on: req.db).filter(\.$project.$id == project.id!).count()
        return ProjectDetail(project: project.dto, context: project.context,
                             learnedContext: project.learnedContext, meetingCount: count)
    }

    r.delete("projects", ":id") { req -> HTTPStatus in
        let p = try req.principal
        let project = try await HubQueries.project(req, id: HubQueries.uuid(req, "id"))
        let meetings = try await MeetingModel.query(on: req.db).filter(\.$project.$id == project.id!).all()
        for m in meetings {
            try? FileManager.default.removeItem(at: req.application.hubPaths.audioDir(workspace: p.workspaceID, meeting: m.id!))
        }
        try await project.delete(on: req.db)
        let dir = ExportMirror(root: req.application.hubPaths.export).projectDir(workspace: p.workspace.name, project: project.name)
        try? FileManager.default.removeItem(at: dir)
        req.application.eventBus.post(HubEvent(kind: .projectDeleted, projectID: project.id))
        return .noContent
    }
}

// MARK: - Meetings

func meetingRoutes(_ r: RoutesBuilder) {
    r.get("meetings") { req -> [Meeting] in
        let p = try req.principal
        var query = MeetingModel.query(on: req.db).filter(\.$workspace.$id == p.workspaceID).with(\.$actionItems)
        if let project = req.query[UUID.self, at: "project"] { query = query.filter(\.$project.$id == project) }
        if let since = HubQueries.date(req.query[String.self, at: "since"]) { query = query.filter(\.$updatedAt >= since) }
        let limit = req.query[Int.self, at: "limit"] ?? 1000
        return try await query.sort(\.$startedAt, .descending).limit(limit).all().map { $0.dto() }
    }

    r.post("meetings") { req -> Meeting in
        let p = try req.principal
        let body = try req.content.decode(CreateMeetingRequest.self)
        let project = try await HubQueries.project(req, id: body.projectID)
        if let id = body.id, let existing = try await MeetingModel.query(on: req.db).filter(\.$id == id).filter(\.$workspace.$id == p.workspaceID).with(\.$actionItems).first() {
            return existing.dto()
        }
        let m = MeetingModel()
        m.id = body.id ?? UUID()
        m.$workspace.id = p.workspaceID
        m.$project.id = project.id!
        m.title = body.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Meeting" : body.title
        m.titleIsAuto = body.titleIsAuto
        m.startedAt = body.startedAt
        m.durationSeconds = body.durationSeconds
        m.meetingStatus = .recorded
        m.source = body.source.rawValue
        m.importedFileName = body.importedFileName
        m.speakerNamesJSON = "{}"
        m.notes = ""
        try await m.save(on: req.db)
        req.application.eventBus.post(HubEvent(kind: .meetingUpdated, meetingID: m.id, projectID: project.id))
        return m.dto(actionItems: [])
    }

    r.get("meetings", ":id") { req -> MeetingDetail in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        return try await HubQueries.detail(req, meeting)
    }

    r.patch("meetings", ":id") { req -> Meeting in
        let p = try req.principal
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let body = try req.content.decode(PatchMeetingRequest.self)
        let oldProject = meeting.project
        if let title = body.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            meeting.title = title
            meeting.titleIsAuto = body.titleIsAuto ?? false
        } else if let auto = body.titleIsAuto {
            meeting.titleIsAuto = auto
        }
        if let notes = body.notes { meeting.notes = notes }
        if let names = body.speakerNames { meeting.speakerNames = names }
        if let d = body.durationSeconds { meeting.durationSeconds = d }
        if let s = body.startedAt { meeting.startedAt = s }
        if let events = body.events { meeting.events = events }
        if let pid = body.projectID, pid != meeting.$project.id {
            let target = try await HubQueries.project(req, id: pid)
            meeting.$project.id = target.id!
            ExportMirror(root: req.application.hubPaths.export).remove(meetingID: meeting.id!, workspace: p.workspace.name, projectName: oldProject.name)
        }
        try await meeting.save(on: req.db)
        let fresh = try await HubQueries.meeting(req, id: meeting.id!)
        HubQueries.broadcastMeeting(req, fresh)
        return fresh.dto()
    }

    r.delete("meetings", ":id") { req -> HTTPStatus in
        let p = try req.principal
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let id = meeting.id!
        try await meeting.delete(on: req.db)
        try? FileManager.default.removeItem(at: req.application.hubPaths.audioDir(workspace: p.workspaceID, meeting: id))
        ExportMirror(root: req.application.hubPaths.export).remove(meetingID: id, workspace: p.workspace.name, projectName: meeting.project.name)
        req.application.eventBus.post(HubEvent(kind: .meetingDeleted, meetingID: id, projectID: meeting.$project.id))
        return .noContent
    }

    /// Queue transcription and/or summarization. Idempotent while a job is already pending.
    r.post("meetings", ":id", "process") { req -> JobInfo in
        let p = try req.principal
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let steps = (try? req.content.decode(ProcessRequest.self).steps).flatMap { $0.isEmpty ? nil : $0 } ?? JobStep.allCases
        if let pending = try await JobModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!)
            .filter(\.$status ~~ [JobStatus.queued.rawValue, JobStatus.running.rawValue]).first() {
            return pending.dto
        }
        if steps.contains(.transcribe) {
            let files = try await AudioFileModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).count()
            guard files > 0 else { throw Abort(.badRequest, reason: "upload audio before processing") }
        } else {
            let transcripts = try await TranscriptModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).count()
            guard transcripts > 0 else { throw Abort(.badRequest, reason: "there is no transcript to summarize") }
        }
        let job = JobModel(workspaceID: p.workspaceID, meetingID: meeting.id!, userID: p.userID, steps: steps)
        try await job.save(on: req.db)
        meeting.meetingStatus = .queued
        meeting.errorMessage = nil
        try await meeting.save(on: req.db)
        req.application.eventBus.post(HubEvent(kind: .meetingUpdated, meetingID: meeting.id, projectID: meeting.$project.id))
        req.application.eventBus.post(HubEvent(kind: .jobUpdated, meetingID: meeting.id, job: job.dto))
        let runner = req.application.jobRunner
        Task { await runner.poke() }
        return job.dto
    }

    r.get("meetings", ":id", "job") { req -> JobInfo in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        guard let job = try await JobModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).sort(\.$createdAt, .descending).first() else {
            throw Abort(.notFound, reason: "no job for this meeting")
        }
        return job.dto
    }

    r.get("jobs") { req -> [JobInfo] in
        let p = try req.principal
        return try await JobModel.query(on: req.db).filter(\.$workspace.$id == p.workspaceID)
            .filter(\.$status ~~ [JobStatus.queued.rawValue, JobStatus.running.rawValue])
            .sort(\.$createdAt).all().map(\.dto)
    }

    r.get("meetings", ":id", "transcript.md") { req -> Response in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let segments = try await TranscriptModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).first()?.segments ?? []
        return HubQueries.markdown(MeetingDocuments.transcriptMarkdown(segments, meeting: meeting.dto()), fileName: "transcript.md")
    }

    r.get("meetings", ":id", "summary.md") { req -> Response in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        guard let summary = try await SummaryModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).first() else {
            throw Abort(.notFound, reason: "no summary yet")
        }
        return HubQueries.markdown(MeetingDocuments.summaryExport(summaryMarkdown: summary.markdown, actionItems: meeting.dto().actionItems,
                                                                  events: meeting.events), fileName: "summary.md")
    }

    r.get("meetings", ":id", "export.md") { req -> Response in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let detail = try await HubQueries.detail(req, meeting)
        let text = MeetingDocuments.everything(meeting: detail.meeting, projectName: detail.projectName, summaryMarkdown: detail.summaryMarkdown,
                                               notes: detail.notes, transcript: detail.transcript)
        return HubQueries.markdown(text, fileName: "\(Fmt.sanitizeFilename(meeting.title)).md")
    }

    /// Clients that processed a meeting themselves (local mode, or older meetings) push the results here.
    r.put("meetings", ":id", "transcript") { req -> MeetingDetail in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let segments = try req.content.decode([TranscriptSegment].self)
        if let existing = try await TranscriptModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).first() {
            try await existing.delete(on: req.db)
        }
        try await TranscriptModel(meetingID: meeting.id!, segments: segments).save(on: req.db)
        if meeting.meetingStatus == .recorded || meeting.meetingStatus == .failed { meeting.meetingStatus = .transcribed }
        try await meeting.save(on: req.db)
        let fresh = try await HubQueries.meeting(req, id: meeting.id!)
        HubQueries.broadcastMeeting(req, fresh)
        return try await HubQueries.detail(req, fresh)
    }

    r.put("meetings", ":id", "summary") { req -> MeetingDetail in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let body = try req.content.decode(PushSummaryRequest.self)
        if let existing = try await SummaryModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).first() {
            try await existing.delete(on: req.db)
        }
        let summary = MeetingSummary(summary: body.markdown)
        try await SummaryModel(meetingID: meeting.id!, summary: summary, markdown: body.markdown, provider: body.provider ?? "client").save(on: req.db)
        if meeting.meetingStatus != .ready { meeting.meetingStatus = .ready }
        meeting.errorMessage = nil
        try await meeting.save(on: req.db)
        let fresh = try await HubQueries.meeting(req, id: meeting.id!)
        HubQueries.broadcastMeeting(req, fresh)
        return try await HubQueries.detail(req, fresh)
    }

    r.get("search") { req -> [Meeting] in
        let p = try req.principal
        let q = (req.query[String.self, at: "q"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let project = req.query[UUID.self, at: "project"]
        var query = MeetingModel.query(on: req.db).filter(\.$workspace.$id == p.workspaceID).with(\.$actionItems)
        if let project { query = query.filter(\.$project.$id == project) }
        let meetings = try await query.sort(\.$startedAt, .descending).all()
        guard !q.isEmpty else { return meetings.map { $0.dto() } }
        let terms = q.split(separator: " ").map(String.init)
        var hits: [Meeting] = []
        for m in meetings {
            var text = [m.title, m.notes].joined(separator: "\n")
            text += m.actionItems.map(\.task).joined(separator: "\n")
            if let s = try await SummaryModel.query(on: req.db).filter(\.$meeting.$id == m.id!).first() { text += "\n" + s.markdown }
            if let t = try await TranscriptModel.query(on: req.db).filter(\.$meeting.$id == m.id!).first() { text += "\n" + t.segmentsJSON }
            let lower = text.lowercased()
            if terms.allSatisfy({ lower.contains($0) }) { hits.append(m.dto()) }
        }
        return hits
    }
}

// MARK: - Action items

func actionItemRoutes(_ r: RoutesBuilder) {
    r.post("meetings", ":id", "action-items") { req -> Meeting in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let body = try req.content.decode(NewActionItemRequest.self)
        let task = body.task.trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty else { throw Abort(.badRequest, reason: "task is empty") }
        let item = ActionItem(task: task, owner: body.owner, due: body.due, isManual: true)
        try await ActionItemModel(item, meetingID: meeting.id!, position: meeting.actionItems.count).save(on: req.db)
        try await meeting.save(on: req.db)   // bumps updated_at
        let fresh = try await HubQueries.meeting(req, id: meeting.id!)
        HubQueries.broadcastMeeting(req, fresh)
        return fresh.dto()
    }

    r.put("meetings", ":id", "action-items") { req -> Meeting in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let items = try req.content.decode([ActionItem].self)
        for row in meeting.actionItems { try await row.delete(on: req.db) }
        for (i, item) in items.enumerated() where !item.task.trimmingCharacters(in: .whitespaces).isEmpty {
            try await ActionItemModel(item, meetingID: meeting.id!, position: i).save(on: req.db)
        }
        try await meeting.save(on: req.db)
        let fresh = try await HubQueries.meeting(req, id: meeting.id!)
        HubQueries.broadcastMeeting(req, fresh)
        return fresh.dto()
    }

    r.patch("meetings", ":id", "action-items", ":item") { req -> Meeting in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let itemID = try HubQueries.uuid(req, "item")
        guard let row = meeting.actionItems.first(where: { $0.id == itemID }) else { throw Abort(.notFound, reason: "no such action item") }
        let body = try req.content.decode(PatchActionItemRequest.self)
        if let task = body.task?.trimmingCharacters(in: .whitespaces), !task.isEmpty { row.task = task }
        if let owner = body.owner { row.owner = owner.isEmpty ? nil : owner }
        if let due = body.due { row.due = due.isEmpty ? nil : due }
        if let done = body.done { row.done = done }
        try await row.save(on: req.db)
        try await meeting.save(on: req.db)
        let fresh = try await HubQueries.meeting(req, id: meeting.id!)
        HubQueries.broadcastMeeting(req, fresh)
        return fresh.dto()
    }

    // Advice is never generated as part of processing — it costs a model call and only happens when asked for.
    r.post("meetings", ":id", "action-items", ":item", "advise") { req -> AdviceResponse in
        let pr = try req.principal
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let itemID = try HubQueries.uuid(req, "item")
        guard let row = meeting.actionItems.first(where: { $0.id == itemID }) else { throw Abort(.notFound, reason: "no such action item") }
        let settings = try await SettingsStore.load(workspaceID: pr.workspaceID, db: req.db, secrets: req.application.secrets)
        let userName = (try? await UserModel.find(pr.userID, on: req.db))?.name ?? settings.userName
        let summarizer = try SummarizerFactory.make(settings.summarizer)
        try await meeting.$project.load(on: req.db)
        let project = meeting.project
        let summary = try await SummaryModel.query(on: req.db).filter(\.$meeting.$id == meeting.id!).first()
        let siblings = try await HubQueries.projectItems(db: req.db, projectID: project.id!, excluding: meeting.id!).open
        let text = try await summarizer.advise(AdviceRequest(
            item: row.dto, meeting: meeting.dto(), projectName: project.name, userContext: project.context,
            learnedContext: project.learnedContext,
            summaryMarkdown: summary?.markdown ?? "(no summary was written for this meeting)",
            otherOpenItems: siblings, userName: userName))
        row.guidance = text
        row.guidanceAt = Date()
        try await row.save(on: req.db)
        try await meeting.save(on: req.db)
        let fresh = try await HubQueries.meeting(req, id: meeting.id!)
        HubQueries.broadcastMeeting(req, fresh)
        return AdviceResponse(itemID: itemID, guidance: text, generatedAt: row.guidanceAt ?? Date())
    }

    r.delete("meetings", ":id", "action-items", ":item") { req -> Meeting in
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let itemID = try HubQueries.uuid(req, "item")
        guard let row = meeting.actionItems.first(where: { $0.id == itemID }) else { throw Abort(.notFound, reason: "no such action item") }
        try await row.delete(on: req.db)
        try await meeting.save(on: req.db)
        let fresh = try await HubQueries.meeting(req, id: meeting.id!)
        HubQueries.broadcastMeeting(req, fresh)
        return fresh.dto()
    }
}
