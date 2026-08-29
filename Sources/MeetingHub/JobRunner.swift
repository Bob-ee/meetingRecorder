import Fluent
import Foundation
import MeetingCore
import MeetingEngine
import Vapor

/// Works through queued jobs one at a time (the speech models are heavy; one meeting at a time is the right speed
/// for a 16 GB machine). Progress goes to the job row, the meeting row and the event bus.
actor JobRunner {
    private let app: Application
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(app: Application) { self.app = app }

    func start() {
        guard !started else { return }
        started = true
        Task.detached(priority: .utility) { await self.loop() }
    }

    /// Wake the loop up (a job was enqueued).
    func poke() {
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }

    private func loop() async {
        let db = app.db
        // Anything that was "running" when the process died goes back to the queue.
        if let stale = try? await JobModel.query(on: db).filter(\.$status == JobStatus.running.rawValue).all() {
            for job in stale { job.jobStatus = .queued; job.progress = nil; try? await job.save(on: db) }
        }
        while true {
            if let job = try? await JobModel.query(on: db).filter(\.$status == JobStatus.queued.rawValue).sort(\.$createdAt).first() {
                await run(job)
            } else {
                let sleeper = Task { try? await Task.sleep(nanoseconds: 30_000_000_000); self.poke() }
                await withCheckedContinuation { c in waiters.append(c) }
                sleeper.cancel()
            }
        }
    }

    private func run(_ job: JobModel) async {
        let db = app.db
        guard let meeting = try? await MeetingModel.query(on: db).filter(\.$id == job.$meeting.id).with(\.$actionItems).with(\.$project).first() else {
            job.jobStatus = .failed; job.error = "meeting no longer exists"; job.finishedAt = Date()
            try? await job.save(on: db)
            return
        }
        job.jobStatus = .running
        job.startedAt = Date()
        job.attempts += 1
        job.error = nil
        try? await job.save(on: db)
        app.eventBus.post(HubEvent(kind: .jobUpdated, meetingID: meeting.id, job: job.dto))
        Log.hub.info("job \(job.id?.uuidString.prefix(8) ?? "?") started: \(job.stepsRaw) for “\(meeting.title)”")

        do {
            let settings = try await SettingsStore.load(workspaceID: job.$workspace.id, db: db, secrets: app.secrets)
            let userName = (try? await UserModel.find(job.$user.id, on: db))?.name ?? settings.userName
            if job.steps.contains(.transcribe) {
                try await transcribe(job: job, meeting: meeting, settings: settings, userName: userName)
            }
            if job.steps.contains(.summarize) {
                try await summarize(job: job, meeting: meeting, settings: settings, userName: userName)
            }
            job.jobStatus = .done
            job.progress = nil
            job.finishedAt = Date()
            try await job.save(on: db)
            Log.hub.info("job \(job.id?.uuidString.prefix(8) ?? "?") done")
        } catch {
            let message = error.localizedDescription
            Log.hub.error("job \(job.id?.uuidString.prefix(8) ?? "?") failed: \(message)")
            job.jobStatus = .failed
            job.error = message
            job.progress = nil
            job.finishedAt = Date()
            try? await job.save(on: db)
            meeting.meetingStatus = .failed
            meeting.errorMessage = message
            try? await meeting.save(on: db)
        }
        app.eventBus.post(HubEvent(kind: .jobUpdated, meetingID: meeting.id, job: job.dto))
        app.eventBus.post(HubEvent(kind: .meetingUpdated, meetingID: meeting.id, projectID: meeting.$project.id))
        await mirror(meeting)
    }

    private func progress(_ job: JobModel, _ meeting: MeetingModel, status: MeetingStatus? = nil, _ text: String?) async {
        job.progress = text
        try? await job.save(on: app.db)
        if let status, meeting.meetingStatus != status {
            meeting.meetingStatus = status
            meeting.errorMessage = nil
            try? await meeting.save(on: app.db)
            app.eventBus.post(HubEvent(kind: .meetingUpdated, meetingID: meeting.id, projectID: meeting.$project.id))
        }
        app.eventBus.post(HubEvent(kind: .jobUpdated, meetingID: meeting.id, job: job.dto))
    }

    private func transcribe(job: JobModel, meeting: MeetingModel, settings: HubSettings, userName: String) async throws {
        let db = app.db
        let meetingID = meeting.id!
        await progress(job, meeting, status: .transcribing, "Preparing speech models…")
        let dir = app.hubPaths.audioDir(workspace: job.$workspace.id, meeting: meetingID)
        let files = try await AudioFileModel.query(on: db).filter(\.$meeting.$id == meetingID).all()
        func url(_ kind: AudioTrackKind) -> URL? {
            files.first { $0.kind == kind.rawValue }.map { dir.appendingPathComponent($0.fileName) }
        }
        let micURL = meeting.source == MeetingSource.live.rawValue ? url(.mic) : nil
        let remoteURL = url(.imported) ?? url(.system)
        guard micURL != nil || remoteURL != nil else {
            throw Abort(.badRequest, reason: "no audio has been uploaded for this meeting")
        }

        let service = TranscriptionService.shared
        await service.setModelVersion(settings.asrVersion)
        let report: @Sendable (String) -> Void = { text in
            Task { await self.progress(job, meeting, text) }
        }
        try await service.prepare(status: report)
        let segments = try await service.transcribe(micURL: micURL, remoteURL: remoteURL, userLabel: userName, status: report)

        if let existing = try await TranscriptModel.query(on: db).filter(\.$meeting.$id == meetingID).first() {
            try await existing.delete(on: db)
        }
        try await TranscriptModel(meetingID: meetingID, segments: segments).save(on: db)
        await progress(job, meeting, status: .transcribed, nil)

        // Raw CAF uploads (if a client ever sends them) are huge; shrink them now that the transcript exists.
        #if canImport(AVFoundation)
        for file in files where file.fileName.lowercased().hasSuffix(".caf") {
            let src = dir.appendingPathComponent(file.fileName)
            AudioArchiver.compressAndReplace(src)
            let dest = src.deletingPathExtension().appendingPathExtension("m4a")
            if FileManager.default.fileExists(atPath: dest.path) {
                file.fileName = dest.lastPathComponent
                file.byteSize = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? file.byteSize
                file.sha256 = nil
                try? await file.save(on: db)
            }
        }
        #endif
    }

    private func summarize(job: JobModel, meeting: MeetingModel, settings: HubSettings, userName: String) async throws {
        let db = app.db
        let meetingID = meeting.id!
        guard let transcript = try await TranscriptModel.query(on: db).filter(\.$meeting.$id == meetingID).first() else {
            throw Abort(.badRequest, reason: "no transcript to summarize")
        }
        let summarizer = try SummarizerFactory.make(settings.summarizer)
        await progress(job, meeting, status: .summarizing, "Summarizing with \(summarizer.displayName)…")

        let project = meeting.project
        let segments = transcript.segments
        var snapshot = meeting.dto()
        let request = SummaryRequest(
            transcriptMarkdown: MeetingDocuments.transcriptMarkdown(segments, meeting: snapshot),
            projectName: project.name, projectContext: project.context,
            meeting: snapshot, userName: userName,
            debugDirectory: app.hubPaths.audioDir(workspace: job.$workspace.id, meeting: meetingID))
        let summary = try await summarizer.summarize(request)

        if meeting.titleIsAuto, let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            meeting.title = title
            snapshot.title = title
        }
        let markdown = Prompts.renderSummary(summary, meeting: snapshot, projectName: project.name)
        if let existing = try await SummaryModel.query(on: db).filter(\.$meeting.$id == meetingID).first() {
            try await existing.delete(on: db)
        }
        try await SummaryModel(meetingID: meetingID, summary: summary, markdown: markdown, provider: summarizer.displayName).save(on: db)

        let existingItems = try await ActionItemModel.query(on: db).filter(\.$meeting.$id == meetingID).sort(\.$position).all()
        let merged = ActionItems.merge(existing: existingItems.map(\.dto), fresh: summary.actionItems)
        for row in existingItems { try await row.delete(on: db) }
        for (i, item) in merged.enumerated() {
            try await ActionItemModel(item, meetingID: meetingID, position: i).save(on: db)
        }
        meeting.meetingStatus = .ready
        meeting.errorMessage = nil
        try await meeting.save(on: db)
        await progress(job, meeting, nil)
    }

    /// Refresh the plain-files copy of a meeting.
    func mirror(_ meeting: MeetingModel) async {
        let db = app.db
        guard let id = meeting.id,
              let fresh = try? await MeetingModel.query(on: db).filter(\.$id == id).with(\.$actionItems).with(\.$project).with(\.$workspace).first()
        else { return }
        let transcript = (try? await TranscriptModel.query(on: db).filter(\.$meeting.$id == id).first())?.segments ?? []
        let summary = try? await SummaryModel.query(on: db).filter(\.$meeting.$id == id).first()
        ExportMirror(root: app.hubPaths.export).write(workspace: fresh.workspace.name, project: fresh.project, meeting: fresh.dto(),
                                                      transcript: transcript, summaryMarkdown: summary?.markdown, notes: fresh.notes)
    }
}
