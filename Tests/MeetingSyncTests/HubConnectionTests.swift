import Foundation
import MeetingCore
import XCTest
@testable import MeetingHub
@testable import MeetingSync

/// The connection as an app uses it: hand it a pairing code and it connects and syncs by itself.
final class HubConnectionTests: HubTestCase {
    private func pairingCode() async throws -> String {
        PairingCode(host: "127.0.0.1", port: hub.port, token: try await hub.token(named: "connected")).string
    }

    private func wait(for what: String, timeout: TimeInterval = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testConnectsSyncsAndHearsAboutChangesMadeElsewhere() async throws {
        let replica = MemoryReplica()
        let connection = HubConnection(replica: replica, ledgerURL: hub.dir.appendingPathComponent("ledger-connection.json"))
        var prepared = false
        connection.prepare = { _ in prepared = true }
        XCTAssertEqual(connection.state, .off)

        connection.use(pairingCode: try await pairingCode())
        try await wait(for: "the first sync") { connection.lastSync != nil }
        XCTAssertEqual(connection.state, .connected)
        XCTAssertEqual(connection.whoAmI?.device, "connected")
        XCTAssertEqual(connection.whoAmI?.workspace.id, hub.workspaceID)
        XCTAssertTrue(prepared)
        XCTAssertNotNil(replica.projects[hub.inbox.id!])

        // Made by another device; an explicit sync brings it in.
        let other = try await hub.client(named: "other")
        let id = try await other.createMeeting(CreateMeetingRequest(
            projectID: hub.inbox.id!, title: "From elsewhere", startedAt: Date(), durationSeconds: 0, source: .live)).id
        await connection.sync()
        XCTAssertEqual(replica.meetings[id]?.meeting.title, "From elsewhere")

        // And a later change arrives without being asked for, on the strength of the hub's event alone.
        _ = try await other.edit(id, MeetingEdit(notes: "pushed by an event"))
        try await wait(for: "the event-driven sync") { replica.meetings[id]?.notes == "pushed by an event" }

        // A local edit goes up shortly after it is made, with nobody calling push.
        replica.meetings[id]?.meeting.title = "Renamed here"
        connection.note(.meeting(id))
        var title: String?
        let deadline = Date().addingTimeInterval(10)
        while title != "Renamed here", Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            title = try await hub.meetingRow(id)?.title
        }
        XCTAssertEqual(title, "Renamed here")

        connection.disconnect()
        XCTAssertEqual(connection.state, .off)
        XCTAssertNil(connection.whoAmI)
    }

    func testARevokedOrUnknownTokenIsRejected() async throws {
        let connection = HubConnection(replica: MemoryReplica(), ledgerURL: hub.dir.appendingPathComponent("ledger-rejected.json"))
        connection.use(pairingCode: PairingCode(host: "127.0.0.1", port: hub.port, token: "mh_nope").string)
        try await wait(for: "the rejection") { if case .rejected = connection.state { return true } else { return false } }
        connection.disconnect()
    }

    func testAnUnreachableHubIsOfflineNotRejected() async throws {
        let connection = HubConnection(replica: MemoryReplica(), ledgerURL: hub.dir.appendingPathComponent("ledger-offline.json"))
        connection.use(pairingCode: PairingCode(host: "127.0.0.1", port: 1, token: "mh_x").string)
        try await wait(for: "the hub to be found unreachable") { if case .offline = connection.state { return true } else { return false } }
        connection.disconnect()
    }

    func testAnUnreadableCodeLeavesItOff() async throws {
        let connection = HubConnection(replica: MemoryReplica(), ledgerURL: hub.dir.appendingPathComponent("ledger-off.json"))
        connection.use(pairingCode: "not a code")
        XCTAssertEqual(connection.state, .off)
        XCTAssertNil(connection.client)
    }

    func testValidateChecksACodeWithoutAdoptingIt() async throws {
        let me = try await HubConnection.validate(pairingCode: try await pairingCode())
        XCTAssertEqual(me.hub.apiVersion, HubAPI.version)
    }
}
