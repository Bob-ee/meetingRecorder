import Fluent
import FluentSQLiteDriver
import Foundation
import MeetingCore
import Vapor
import XCTest
@testable import MeetingHub
@testable import MeetingSync

/// A hub that was running before the change feed existed has to come up with everything it already held
/// visible to a device syncing from nothing.
@MainActor
final class MigrationTests: XCTestCase {
    func testRowsFromBeforeTheChangeFeedAreAllInIt() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetinghub-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let userID = UUID(), workspaceID = UUID(), projectID = UUID()
        let meetingIDs = [UUID(), UUID(), UUID()]

        // The database as schema V3 left it, filled in without the models (they already expect V4's columns).
        let old = try await Application.make(Environment(name: "testing", arguments: ["meetinghub", "test"]))
        old.logger.logLevel = .error
        do {
            old.databases.use(.sqlite(.file(dir.appendingPathComponent("hub.sqlite").path)), as: .sqlite)
            old.migrations.add(CreateSchemaV1())
            old.migrations.add(AddCalendarFieldsV2())
            old.migrations.add(AddProjectContextFieldsV3())
            try await old.autoMigrate()
            let sql = try XCTUnwrap(old.db as? any SQLDatabase)
            try await sql.raw("INSERT INTO users (id, name) VALUES (\(bind: userID), \(bind: "Tester"))").run()
            try await sql.raw("""
                INSERT INTO workspaces (id, name, owner_id, plan) \
                VALUES (\(bind: workspaceID), \(bind: "Tester's meetings"), \(bind: userID), \(bind: "self-hosted"))
                """).run()
            try await sql.raw("""
                INSERT INTO projects (id, workspace_id, name, context) \
                VALUES (\(bind: projectID), \(bind: workspaceID), \(bind: "Inbox"), \(bind: "old context"))
                """).run()
            for (i, id) in meetingIDs.enumerated() {
                try await sql.raw("""
                    INSERT INTO meetings (id, workspace_id, project_id, title, title_is_auto, started_at, duration_seconds, \
                    status, source, speaker_names, notes) \
                    VALUES (\(bind: id), \(bind: workspaceID), \(bind: projectID), \(bind: "Old meeting \(i)"), \(bind: false), \
                    \(bind: Date(timeIntervalSince1970: 1_780_000_000 + Double(i))), \(bind: 60.0), \
                    \(bind: "ready"), \(bind: "live"), \(bind: "{}"), \(bind: "old notes"))
                    """).run()
            }
        } catch {
            try? await old.asyncShutdown()
            throw error
        }
        try await old.asyncShutdown()

        // Today's hub on that directory: V4 runs at startup.
        let hub = try await TestHub.start(in: dir)
        do {
            XCTAssertEqual(hub.workspaceID, workspaceID)
            let rows = try await MeetingModel.query(on: hub.app.db).all()
            XCTAssertEqual(rows.map(\.revision), [1, 1, 1])
            let project = try await ProjectModel.find(projectID, on: hub.app.db)
            XCTAssertEqual(project?.revision, 1)
            let head = try await hub.revision()
            XCTAssertEqual(head, 1)

            let client = try await hub.client()
            let everything = try await client.changes(since: 0)
            XCTAssertEqual(Set(everything.meetings.map(\.id)), Set(meetingIDs))
            XCTAssertEqual(everything.meetings.first?.notes, "old notes")
            XCTAssertEqual(everything.projects.map(\.id), [projectID])
            XCTAssertEqual(everything.projects.first?.context, "old context")
            XCTAssertEqual(everything.projects.first?.meetingCount, 3)
            XCTAssertEqual(everything.revision, 1)
            XCTAssertFalse(everything.hasMore)

            let nothing = try await client.changes(since: everything.revision)
            XCTAssertTrue(nothing.meetings.isEmpty && nothing.projects.isEmpty && nothing.removed.isEmpty)

            // The first write after the migration is the first new revision, and only it is news.
            _ = try await client.edit(meetingIDs[0], MeetingEdit(notes: "new notes"))
            let news = try await client.changes(since: everything.revision)
            XCTAssertEqual(news.meetings.map(\.id), [meetingIDs[0]])
            XCTAssertEqual(news.revision, 2)

            // Running the migrations again (every start does) changes nothing.
            try await hub.app.autoMigrate()
            let again = try await hub.revision()
            XCTAssertEqual(again, 2)
        } catch {
            await hub.stop()
            throw error
        }
        await hub.stop()
    }
}
