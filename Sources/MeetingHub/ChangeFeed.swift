import Fluent
import FluentSQLiteDriver
import Foundation
import MeetingCore
import Vapor

/// How devices find out what changed while they weren't looking.
///
/// Every write to a project or meeting takes the workspace's next revision and records it on the row; a delete
/// leaves a tombstone carrying one. "Everything after revision N" is then an exact question with an exact
/// answer — no device clock is involved, and a phone that was asleep for a week misses nothing.
///
/// The stamping happens in model middleware rather than at each call site, so there is no write that can
/// forget to do it. That also makes every save a real write: Fluent skips the UPDATE for a model with no dirty
/// fields, and a fresh revision is always a dirty field.
protocol Revisioned: Model where IDValue == UUID {
    static var tombstoneKind: Tombstone.Kind { get }
    var revision: Int64 { get set }
    var workspaceID: UUID { get }
}

extension ProjectModel: Revisioned {
    static let tombstoneKind = Tombstone.Kind.project
    var workspaceID: UUID { $workspace.id }
}

extension MeetingModel: Revisioned {
    static let tombstoneKind = Tombstone.Kind.meeting
    var workspaceID: UUID { $workspace.id }
}

struct RevisionMiddleware<M: Revisioned>: AsyncModelMiddleware {
    func create(model: M, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await db.transaction { tx in
            model.revision = try await ChangeFeed.nextRevision(in: model.workspaceID, on: tx)
            try await next.create(model, on: tx)
        }
    }

    func update(model: M, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await db.transaction { tx in
            model.revision = try await ChangeFeed.nextRevision(in: model.workspaceID, on: tx)
            try await next.update(model, on: tx)
        }
    }

    func delete(model: M, force: Bool, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await db.transaction { tx in
            let revision = try await ChangeFeed.nextRevision(in: model.workspaceID, on: tx)
            try await TombstoneModel(workspaceID: model.workspaceID, kind: M.tombstoneKind,
                                     entityID: try model.requireID(), revision: revision).create(on: tx)
            try await next.delete(model, force: force, on: tx)
        }
    }
}

enum ChangeFeed {
    static let defaultPageSize = 200
    static let maxPageSize = 500

    /// Take the workspace's next revision.
    ///
    /// This has to be a write, and the first thing its transaction does to the row it stamps: SQLite lets one
    /// transaction write at a time, so holding the write lock from here until commit means revisions are
    /// committed in the order they are handed out. A reader can therefore never see revision N+1 while N is
    /// still on its way — which is what lets a device say "I have everything up to N" and mean it.
    static func nextRevision(in workspaceID: UUID, on db: any Database) async throws -> Int64 {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "the change feed needs an SQL database")
        }
        let row = try await sql.raw("""
            UPDATE \(ident: WorkspaceModel.schema) SET revision = revision + 1 \
            WHERE id = \(bind: workspaceID) RETURNING revision
            """).first()
        guard let row else { throw Abort(.internalServerError, reason: "no such workspace") }
        return try row.decode(column: "revision", as: Int64.self)
    }

    /// Everything in the workspace written after `since`, oldest first, at most `limit` meetings at a time.
    static func changes(since requested: Int64, limit: Int, workspaceID: UUID, on db: any Database) async throws -> ChangeSet {
        // Read the high-water mark before the rows. Whatever is committed after this point has a higher
        // revision and is picked up by the next request; nothing at or below it can still be in flight.
        guard let head = try await WorkspaceModel.find(workspaceID, on: db)?.revision else {
            throw Abort(.notFound, reason: "no such workspace")
        }
        // A cursor from the future means the hub's data was replaced (restored from a backup, say): start over.
        let since = requested > head ? 0 : requested
        let limit = min(max(limit, 1), maxPageSize)

        var meetings = try await MeetingModel.query(on: db)
            .filter(\.$workspace.$id == workspaceID)
            .filter(\.$revision > since).filter(\.$revision <= head)
            .with(\.$actionItems)
            .sort(\.$revision).limit(limit + 1).all()
        let hasMore = meetings.count > limit
        if hasMore { meetings.removeLast() }
        let upTo = hasMore ? meetings.last?.revision ?? head : head

        let projects = try await ProjectModel.query(on: db)
            .filter(\.$workspace.$id == workspaceID)
            .filter(\.$revision > since).filter(\.$revision <= upTo)
            .sort(\.$revision).all()
        let tombstones = try await TombstoneModel.query(on: db)
            .filter(\.$workspace.$id == workspaceID)
            .filter(\.$revision > since).filter(\.$revision <= upTo)
            .sort(\.$revision).all()

        var details: [ProjectDetail] = []
        for project in projects { details.append(try await detail(project, on: db)) }
        return ChangeSet(revision: upTo, projects: details, meetings: try await records(meetings, on: db),
                         removed: tombstones.compactMap(\.dto), hasMore: hasMore)
    }

    static func detail(_ project: ProjectModel, on db: any Database) async throws -> ProjectDetail {
        let count = try await MeetingModel.query(on: db).filter(\.$project.$id == project.requireID()).count()
        return ProjectDetail(project: project.dto, context: project.context,
                             learnedContext: project.learnedContext, meetingCount: count)
    }

    /// Requires `actionItems` to be loaded.
    static func record(_ meeting: MeetingModel, on db: any Database) async throws -> MeetingRecord {
        try await records([meeting], on: db)[0]
    }

    /// Requires `actionItems` to be loaded on each meeting.
    static func records(_ meetings: [MeetingModel], on db: any Database) async throws -> [MeetingRecord] {
        let tags = try await contentTags(for: meetings.compactMap(\.id), on: db)
        return meetings.map { MeetingRecord(meeting: $0.dto(), notes: $0.notes, contentTag: $0.id.flatMap { tags[$0] }) }
    }

    /// One tag per meeting that has a transcript or a summary, built from when each was written — both are
    /// replaced wholesale, never edited, so their creation times change exactly when the content does.
    private static func contentTags(for ids: [UUID], on db: any Database) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        func stamp(_ date: Date?) -> String { date.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "0" }
        var transcripts: [UUID: String] = [:], summaries: [UUID: String] = [:]
        // Only the columns needed: the transcript and summary bodies are large and this runs for every page.
        for row in try await TranscriptModel.query(on: db).filter(\.$meeting.$id ~~ ids)
            .field(\.$id).field(\.$meeting.$id).field(\.$createdAt).all() {
            transcripts[row.$meeting.id] = stamp(row.createdAt)
        }
        for row in try await SummaryModel.query(on: db).filter(\.$meeting.$id ~~ ids)
            .field(\.$id).field(\.$meeting.$id).field(\.$createdAt).all() {
            summaries[row.$meeting.id] = stamp(row.createdAt)
        }
        var tags: [UUID: String] = [:]
        for id in ids where transcripts[id] != nil || summaries[id] != nil {
            tags[id] = "\(transcripts[id] ?? "0")-\(summaries[id] ?? "0")"
        }
        return tags
    }

    /// True once something has been deleted — the hub then refuses to create it again, so a device that was
    /// away for the delete can't quietly undo it by pushing its stale copy.
    static func isBuried(_ kind: Tombstone.Kind, _ id: UUID, workspaceID: UUID, on db: any Database) async throws -> Bool {
        try await TombstoneModel.query(on: db)
            .filter(\.$workspace.$id == workspaceID)
            .filter(\.$kind == kind.rawValue).filter(\.$entityID == id).count() > 0
    }
}
