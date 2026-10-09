import Fluent
import FluentSQLiteDriver
import Foundation
import MeetingCore
import Vapor
import XCTest
@testable import MeetingHub
@testable import MeetingSync

/// The real hub, in this process, on a port of its own, with a throwaway data directory.
@MainActor
final class TestHub {
    let app: Application
    let dir: URL
    let port: Int
    let user: UserModel
    let workspace: WorkspaceModel
    let inbox: ProjectModel

    var workspaceID: UUID { workspace.id! }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// `dir` lets a test start a hub on a data directory it prepared itself.
    static func start(in existing: URL? = nil) async throws -> TestHub {
        let dir = existing ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("meetinghub-tests-\(UUID().uuidString)", isDirectory: true)
        setenv("MEETINGHUB_DATA", dir.path, 1)
        // Anything but `serve`, so the job worker — which wants speech models — stays out of it.
        let app = try await Application.make(Environment(name: "testing", arguments: ["meetinghub", "test"]))
        do {
            app.logger.logLevel = .error
            try await configure(app)
            Log.mirrorToStderr = false
            // An event stream is only noticed to be gone at its next ping; don't make every teardown wait for one.
            app.http.server.configuration.shutdownTimeout = .milliseconds(200)

            let user: UserModel
            let workspace: WorkspaceModel
            if let existing = try await UserModel.query(on: app.db).first(),
               let ws = try await WorkspaceModel.query(on: app.db).filter(\.$owner.$id == existing.id!).first() {
                user = existing
                workspace = ws
            } else {
                user = UserModel(name: "Tester")
                try await user.save(on: app.db)
                workspace = WorkspaceModel(name: "Tester's meetings", ownerID: user.id!)
                try await workspace.save(on: app.db)
                try await WorkspaceMemberModel(workspaceID: workspace.id!, userID: user.id!, role: "owner").save(on: app.db)
            }
            let inbox: ProjectModel
            if let existing = try await ProjectModel.query(on: app.db).filter(\.$name == "Inbox").first() {
                inbox = existing
            } else {
                inbox = ProjectModel(workspaceID: workspace.id!, name: "Inbox")
                try await inbox.save(on: app.db)
            }

            try await app.asyncBoot()
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            guard let port = app.http.server.shared.localAddress?.port else {
                throw Abort(.internalServerError, reason: "the test hub has no port")
            }
            return TestHub(app: app, dir: dir, port: port, user: user, workspace: workspace, inbox: inbox)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    private init(app: Application, dir: URL, port: Int, user: UserModel, workspace: WorkspaceModel, inbox: ProjectModel) {
        self.app = app; self.dir = dir; self.port = port; self.user = user; self.workspace = workspace; self.inbox = inbox
    }

    /// Stop listening now, but take the application down one test later. The hub answers a write and then
    /// refreshes its Markdown mirror in a task of its own; that task must still find a working application.
    func stop() async {
        await app.server.shutdown()
        await TestHub.retired?.dismantle()
        TestHub.retired = self
    }

    private func dismantle() async {
        try? await app.asyncShutdown()
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor private static var retired: TestHub?

    /// A freshly paired device's token. The code the hub prints names its tailnet host; the tests talk to
    /// 127.0.0.1, so only the token is taken from it.
    func token(named name: String = "test device") async throws -> String {
        let code = try await Pairing.create(deviceName: name, user: user, workspace: workspace, app: app)
        return try XCTUnwrap(PairingCode(parsing: code)).token
    }

    func client(named name: String = "test device") async throws -> HubClient {
        HubClient(baseURL: baseURL, token: try await token(named: name))
    }

    func revision() async throws -> Int64 {
        let workspace = try await WorkspaceModel.find(workspaceID, on: app.db)
        return try XCTUnwrap(workspace).revision
    }

    func meetingRow(_ id: UUID) async throws -> MeetingModel? {
        try await MeetingModel.query(on: app.db).filter(\.$id == id).with(\.$actionItems).first()
    }
}

/// A device's data, held in memory. Mutators do what an app does: change the copy, then tell the engine.
@MainActor
final class MemoryReplica: SyncReplica {
    var projects: [UUID: ProjectDetail] = [:]
    var meetings: [UUID: MeetingRecord] = [:]
    var transcripts: [UUID: [TranscriptSegment]] = [:]
    var summaries: [UUID: String] = [:]
    /// How many times the hub's content was written here.
    var contentWrites = 0

    func projectRecord(_ id: UUID) -> ProjectDetail? { projects[id] }
    func meetingRecord(_ id: UUID) -> MeetingRecord? { meetings[id] }
    func apply(_ project: ProjectDetail) { projects[project.id] = project }
    func apply(_ meeting: MeetingRecord) { meetings[meeting.id] = meeting }

    func applyContent(transcript: [TranscriptSegment], summary: String?, for meetingID: UUID) {
        transcripts[meetingID] = transcript
        summaries[meetingID] = summary
        contentWrites += 1
    }

    func discardProject(_ id: UUID) {
        projects[id] = nil
        meetings = meetings.filter { $0.value.meeting.projectID != id }
    }

    func discardMeeting(_ id: UUID) { meetings[id] = nil }
}

/// One device: its data, its engine, its own token.
@MainActor
final class Device {
    let replica = MemoryReplica()
    let engine: SyncEngine
    let client: HubClient

    init(hub: TestHub, name: String) async throws {
        client = try await hub.client(named: name)
        engine = SyncEngine(replica: replica, ledgerURL: hub.dir.appendingPathComponent("ledger-\(name)-\(UUID().uuidString).json"))
        engine.use(workspace: hub.workspaceID)
    }

    func push() async throws { try await engine.push(with: client) }
    func pull() async throws { try await engine.pull(with: client) }
    func sync() async throws { try await push(); try await pull() }

    func meeting(_ id: UUID) -> MeetingRecord? { replica.meetings[id] }

    @discardableResult
    func createProject(_ name: String, context: String = "") -> UUID {
        let project = Project(name: name)
        replica.projects[project.id] = ProjectDetail(project: project, context: context, meetingCount: 0)
        engine.note(.project(project.id))
        return project.id
    }

    func editProject(_ id: UUID, _ change: (inout ProjectDetail) -> Void) {
        guard var project = replica.projects[id] else { return }
        change(&project)
        replica.projects[id] = project
        engine.note(.project(id))
    }

    func deleteProject(_ id: UUID) {
        replica.discardProject(id)
        engine.note(.removedProject(id))
    }

    @discardableResult
    func createMeeting(id: UUID = UUID(), in projectID: UUID, title: String, notes: String = "",
                       items: [ActionItem] = []) -> UUID {
        let meeting = Meeting(id: id, projectID: projectID, title: title, titleIsAuto: false, actionItems: items)
        replica.meetings[id] = MeetingRecord(meeting: meeting, notes: notes)
        engine.note(.newMeeting(id))
        return id
    }

    func edit(_ id: UUID, _ change: (inout MeetingRecord) -> Void) {
        guard var record = replica.meetings[id] else { return }
        change(&record)
        replica.meetings[id] = record
        engine.note(.meeting(id))
    }

    func deleteMeeting(_ id: UUID) {
        replica.meetings[id] = nil
        engine.note(.removedMeeting(id))
    }
}

/// Tests share one shape: a hub that comes up before each and goes away after.
@MainActor
class HubTestCase: XCTestCase {
    var hub: TestHub!

    override func setUp() async throws {
        hub = try await TestHub.start()
    }

    override func tearDown() async throws {
        await hub?.stop()
        hub = nil
    }

    func device(_ name: String) async throws -> Device { try await Device(hub: hub, name: name) }
}
