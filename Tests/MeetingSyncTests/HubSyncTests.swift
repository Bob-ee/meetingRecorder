import Fluent
import Foundation
import MeetingCore
import XCTest
@testable import MeetingHub
@testable import MeetingSync

/// Two devices and a real hub, talking over real HTTP. Each test is one way things used to go wrong, or one
/// promise the change feed makes.
final class HubSyncTests: HubTestCase {
    private var inboxID: UUID { hub.inbox.id! }

    /// A meeting both devices have, with A as the one that made it.
    private func sharedMeeting(_ a: Device, _ b: Device, title: String = "Weekly", items: [ActionItem] = []) async throws -> UUID {
        let id = a.createMeeting(in: inboxID, title: title, items: items)
        try await a.sync()
        try await b.sync()
        XCTAssertNotNil(b.meeting(id))
        return id
    }

    // MARK: a — creation reaches the other device

    func testProjectAndMeetingMadeOnOneDeviceReachTheOther() async throws {
        let a = try await device("a"), b = try await device("b")
        let projectID = a.createProject("Launch", context: "Ships in May")
        let meetingID = a.createMeeting(in: projectID, title: "Kickoff", notes: "bring slides",
                                        items: [ActionItem(task: "Book room", isManual: true)])
        try await a.sync()
        XCTAssertFalse(a.engine.hasUnsentWork)

        try await b.sync()
        XCTAssertEqual(b.replica.projects[projectID]?.project.name, "Launch")
        XCTAssertEqual(b.replica.projects[projectID]?.context, "Ships in May")
        let record = try XCTUnwrap(b.meeting(meetingID))
        XCTAssertEqual(record.meeting.title, "Kickoff")
        XCTAssertEqual(record.meeting.projectID, projectID)
        XCTAssertEqual(record.notes, "bring slides")
        XCTAssertEqual(record.meeting.actionItems.map(\.task), ["Book room"])
        XCTAssertNotNil(b.replica.projects[inboxID], "the hub's own Inbox comes down too")
    }

    // MARK: b — different fields

    func testEditsToDifferentFieldsBothSurvive() async throws {
        let a = try await device("a"), b = try await device("b")
        let id = try await sharedMeeting(a, b)

        a.edit(id) { $0.meeting.title = "Weekly sync" }
        b.edit(id) { $0.notes = "B's notes" }
        try await a.sync()
        try await b.sync()
        try await a.sync()

        for device in [a, b] {
            XCTAssertEqual(device.meeting(id)?.meeting.title, "Weekly sync")
            XCTAssertEqual(device.meeting(id)?.notes, "B's notes")
            XCTAssertFalse(device.engine.hasUnsentWork)
        }
    }

    // MARK: c — the whole-list-replace bug

    func testCheckOffOnOneDeviceSurvivesAnItemAddedFromAStaleCopyOnAnother() async throws {
        let a = try await device("a"), b = try await device("b")
        let first = ActionItem(task: "Send deck"), second = ActionItem(task: "Email Ann")
        let id = try await sharedMeeting(a, b, items: [first, second])

        a.edit(id) { $0.meeting.actionItems[0].done = true }
        try await a.sync()
        // B hasn't heard about the check-off and adds an item to its stale list.
        b.edit(id) { $0.meeting.actionItems.append(ActionItem(task: "Book room", isManual: true)) }
        try await b.sync()
        try await a.sync()

        for device in [a, b] {
            let items = try XCTUnwrap(device.meeting(id)).meeting.actionItems
            XCTAssertEqual(items.map(\.task), ["Send deck", "Email Ann", "Book room"])
            XCTAssertEqual(items.map(\.done), [true, false, false])
        }
    }

    func testItemRemovedOnOneDeviceAndAnotherEditedOnTheOther() async throws {
        let a = try await device("a"), b = try await device("b")
        let id = try await sharedMeeting(a, b, items: [ActionItem(task: "One"), ActionItem(task: "Two")])

        a.edit(id) { $0.meeting.actionItems.removeFirst() }
        b.edit(id) { $0.meeting.actionItems[1].owner = "Bo" }
        try await a.sync()
        try await b.sync()
        try await a.sync()

        for device in [a, b] {
            let items = try XCTUnwrap(device.meeting(id)).meeting.actionItems
            XCTAssertEqual(items.map(\.task), ["Two"])
            XCTAssertEqual(items.first?.owner, "Bo")
        }
    }

    // MARK: d — the same item on both

    func testSameItemEditedOnBothConvergesWithoutPingPong() async throws {
        let a = try await device("a"), b = try await device("b")
        let id = try await sharedMeeting(a, b, items: [ActionItem(task: "Send deck")])

        a.edit(id) { $0.meeting.actionItems[0].task = "Send the deck to Ann" }
        b.edit(id) { $0.meeting.actionItems[0].task = "Send the deck to Bo" }
        try await a.push()
        try await b.push()   // last push wins
        try await a.sync()
        try await b.sync()

        XCTAssertEqual(a.meeting(id)?.meeting.actionItems.map(\.task), ["Send the deck to Bo"])
        XCTAssertEqual(b.meeting(id)?.meeting.actionItems.map(\.task), ["Send the deck to Bo"])
        XCTAssertFalse(a.engine.hasUnsentWork)
        XCTAssertFalse(b.engine.hasUnsentWork)

        // Converged means quiet: more rounds write nothing on the hub.
        let settled = try await hub.revision()
        for _ in 0..<2 {
            try await a.sync()
            try await b.sync()
        }
        let after = try await hub.revision()
        XCTAssertEqual(after, settled)
    }

    // MARK: e — the resurrection bug

    func testMeetingDeletedElsewhereIsNotBroughtBackByAStaleEdit() async throws {
        let a = try await device("a"), b = try await device("b")
        let id = try await sharedMeeting(a, b)

        a.deleteMeeting(id)
        try await a.sync()
        b.edit(id) { $0.notes = "typed while offline" }   // B doesn't know yet
        try await b.sync()

        XCTAssertNil(b.meeting(id))
        XCTAssertFalse(b.engine.hasUnsentWork)
        let row = try await hub.meetingRow(id)
        XCTAssertNil(row)

        do {
            _ = try await b.client.createMeeting(CreateMeetingRequest(id: id, projectID: inboxID, title: "Weekly",
                                                                      startedAt: Date(), durationSeconds: 0, source: .live))
            XCTFail("the hub took back a meeting that was deleted")
        } catch let error as HubClientError {
            XCTAssertTrue(error.isGone, "\(error)")
        }
    }

    func testMeetingMadeHereButDeletedOnTheHubBeforeItsFirstPushIsDropped() async throws {
        let a = try await device("a"), b = try await device("b")
        // B's creation reaches the hub but B never hears back (as after a lost reply): its ledger still says unsent.
        let id = UUID()
        _ = try await a.client.createMeeting(CreateMeetingRequest(id: id, projectID: inboxID, title: "Weekly",
                                                                  startedAt: Date(), durationSeconds: 0, source: .live))
        try await a.client.deleteMeeting(id)
        b.createMeeting(id: id, in: inboxID, title: "Weekly")
        try await b.push()
        XCTAssertNil(b.meeting(id))
        XCTAssertFalse(b.engine.hasUnsentWork)
    }

    // MARK: f — deleting a project

    func testProjectDeletedOnOneDeviceGoesWithItsMeetingsOnTheOther() async throws {
        let a = try await device("a"), b = try await device("b")
        let projectID = a.createProject("Doomed")
        let first = a.createMeeting(in: projectID, title: "One")
        let second = a.createMeeting(in: projectID, title: "Two")
        let elsewhere = a.createMeeting(in: inboxID, title: "Stays")
        try await a.sync()
        try await b.sync()
        XCTAssertNotNil(b.meeting(first))

        a.deleteProject(projectID)
        try await a.sync()
        try await b.sync()

        XCTAssertNil(b.replica.projects[projectID])
        XCTAssertNil(b.meeting(first))
        XCTAssertNil(b.meeting(second))
        XCTAssertNotNil(b.meeting(elsewhere))
        XCTAssertFalse(a.engine.hasUnsentWork)

        let removed = Set(try await a.client.changes(since: 0).removed)
        XCTAssertEqual(removed, [Tombstone(kind: .project, id: projectID),
                                 Tombstone(kind: .meeting, id: first), Tombstone(kind: .meeting, id: second)])

        do {
            _ = try await b.client.createProject(CreateProjectRequest(id: projectID, name: "Doomed"))
            XCTFail("the hub took back a project that was deleted")
        } catch let error as HubClientError {
            XCTAssertTrue(error.isGone, "\(error)")
        }
    }

    // MARK: g — paging

    func testPagingYieldsEveryMeetingExactlyOnce() async throws {
        let client = try await hub.client()
        var made: Set<UUID> = []
        for i in 0..<7 {
            made.insert(try await client.createMeeting(CreateMeetingRequest(
                projectID: inboxID, title: "Meeting \(i)", startedAt: Date(), durationSeconds: 0, source: .live)).id)
        }

        var cursor: Int64 = 0
        var seen: [UUID] = []
        var projects: [UUID] = []
        var pages = 0
        while true {
            let page = try await ChangeFeed.changes(since: cursor, limit: 2, workspaceID: hub.workspaceID, on: hub.app.db)
            XCTAssertLessThanOrEqual(page.meetings.count, 2)
            XCTAssertGreaterThan(page.revision, cursor)
            seen += page.meetings.map(\.id)
            projects += page.projects.map(\.id)
            cursor = page.revision
            pages += 1
            if !page.hasMore { break }
        }
        XCTAssertEqual(pages, 4)
        XCTAssertEqual(seen.count, 7)
        XCTAssertEqual(Set(seen), made)
        XCTAssertEqual(projects, [inboxID])
        let head = try await hub.revision()
        XCTAssertEqual(cursor, head)
        let nothing = try await client.changes(since: cursor)
        XCTAssertTrue(nothing.meetings.isEmpty && nothing.projects.isEmpty && nothing.removed.isEmpty && !nothing.hasMore)
    }

    func testPagingOverHTTPAndThroughTheEngine() async throws {
        let a = try await device("a")
        let client = a.client
        for i in 0..<5 {
            _ = try await client.createMeeting(CreateMeetingRequest(
                projectID: inboxID, title: "Meeting \(i)", startedAt: Date(), durationSeconds: 0, source: .live))
        }
        var request = URLRequest(url: hub.baseURL.appendingPathComponent("api/v1/changes"))
        request.url = URL(string: "\(hub.baseURL)/api/v1/changes?since=0&limit=2")
        request.setValue("Bearer \(client.token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let page = try jsonDecoder.decode(ChangeSet.self, from: data)
        XCTAssertEqual(page.meetings.count, 2)
        XCTAssertTrue(page.hasMore)

        try await a.pull()
        XCTAssertEqual(a.replica.meetings.count, 5)
    }

    func testACursorFromTheFutureStartsOver() async throws {
        let client = try await hub.client()
        let id = try await client.createMeeting(CreateMeetingRequest(
            projectID: inboxID, title: "Only", startedAt: Date(), durationSeconds: 0, source: .live)).id
        let changes = try await client.changes(since: 1_000_000)
        XCTAssertEqual(changes.meetings.map(\.id), [id])
        let head = try await hub.revision()
        XCTAssertEqual(changes.revision, head)
    }

    // MARK: h — concurrent writes

    func testConcurrentWritesGetDistinctIncreasingRevisions() async throws {
        let client = try await hub.client()
        let count = 24
        var ids: [UUID] = []
        for i in 0..<count {
            ids.append(try await client.createMeeting(CreateMeetingRequest(
                projectID: inboxID, title: "Meeting \(i)", startedAt: Date(), durationSeconds: 0, source: .live)).id)
        }
        let before = try await hub.revision()
        let inbox = inboxID

        // Every kind of write at once: composite edits (a transaction around nested ones), legacy patches,
        // and new meetings — none may deadlock or come back SQLITE_BUSY.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask {
                    if i % 3 == 0 {
                        _ = try await client.patchMeeting(id, PatchMeetingRequest(notes: "patched \(i)"))
                    } else {
                        _ = try await client.edit(id, MeetingEdit(notes: "edited \(i)",
                                                                  addedItems: [ActionItem(task: "Item \(i)", isManual: true)]))
                    }
                }
            }
            for i in 0..<8 {
                group.addTask {
                    _ = try await client.createMeeting(CreateMeetingRequest(
                        projectID: inbox, title: "Extra \(i)", startedAt: Date(), durationSeconds: 0, source: .live))
                }
            }
            try await group.waitForAll()
        }

        let rows = try await MeetingModel.query(on: hub.app.db).all()
        XCTAssertEqual(rows.count, count + 8)
        XCTAssertEqual(Set(rows.map(\.revision)).count, rows.count, "two meetings share a revision")
        let head = try await hub.revision()
        XCTAssertEqual(rows.map(\.revision).max(), head)
        XCTAssertTrue(rows.allSatisfy { $0.revision > before })

        let all = try await client.changes(since: 0)
        XCTAssertEqual(Set(all.meetings.map(\.id)), Set(rows.compactMap(\.id)))
        let since = try await client.changes(since: before)
        XCTAssertEqual(since.meetings.count, count + 8)
        for id in ids {
            let row = try await hub.meetingRow(id)
            XCTAssertFalse(row?.notes.isEmpty ?? true)
        }
    }

    func testReadersNeverSkipARevisionWhileWritesAreInFlight() async throws {
        // Follow the feed while writes land. If a reader could ever be handed revision N+1 before N was
        // committed, some meeting's last write would be missing from what it collected.
        let writer = try await hub.client(named: "writer"), reader = try await hub.client(named: "reader")
        var ids: [UUID] = []
        for i in 0..<12 {
            ids.append(try await writer.createMeeting(CreateMeetingRequest(
                projectID: inboxID, title: "Meeting \(i)", startedAt: Date(), durationSeconds: 0, source: .live)).id)
        }
        let targets = ids
        let progress = Progress()
        let writing = Task { @MainActor in
            defer { progress.finished = true }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for round in 0..<5 {
                    for id in targets {
                        group.addTask { _ = try await writer.edit(id, MeetingEdit(notes: "round \(round)")) }
                    }
                }
                try await group.waitForAll()
            }
        }
        var cursor: Int64 = 0
        var latest: [UUID: String] = [:]
        func follow() async throws {
            var more = true
            while more {
                let page = try await reader.changes(since: cursor)
                XCTAssertGreaterThanOrEqual(page.revision, cursor)
                for record in page.meetings { latest[record.id] = record.notes }
                cursor = page.revision
                more = page.hasMore
            }
        }
        while !progress.finished { try await follow() }
        try await writing.value
        try await follow()

        for id in ids {
            let row = try await hub.meetingRow(id)
            XCTAssertEqual(latest[id], row?.notes, "the feed's last word on a meeting isn't what the hub holds")
        }
    }

    // MARK: i — values the hub normalises

    func testATitleTheHubTrimsComesBackTrimmedAndClean() async throws {
        let a = try await device("a")
        let id = a.createMeeting(in: inboxID, title: "Weekly")
        try await a.sync()

        a.edit(id) { $0.meeting.title = "Planning   " }
        try await a.push()
        XCTAssertEqual(a.meeting(id)?.meeting.title, "Planning")
        XCTAssertFalse(a.engine.hasUnsentWork)

        // A title the hub won't take at all (empty) settles on what the hub kept, not on a retry loop.
        a.edit(id) { $0.meeting.title = "  " }
        try await a.push()
        XCTAssertEqual(a.meeting(id)?.meeting.title, "Planning")
        XCTAssertFalse(a.engine.hasUnsentWork)
        let settled = try await hub.revision()
        try await a.sync()
        let after = try await hub.revision()
        XCTAssertEqual(after, settled)
    }

    func testAnEditMadeWhileAPushIsInFlightIsNotLost() async throws {
        let a = try await device("a")
        let id = a.createMeeting(in: inboxID, title: "Weekly")
        try await a.sync()

        a.edit(id) { $0.notes = "first" }
        let pushing = Task { try await a.push() }
        await Task.yield()
        a.edit(id) { $0.meeting.title = "Typed during the push" }
        try await pushing.value
        try await a.sync()

        let row = try await hub.meetingRow(id)
        XCTAssertEqual(row?.notes, "first")
        XCTAssertEqual(row?.title, "Typed during the push")
        XCTAssertEqual(a.meeting(id)?.meeting.title, "Typed during the push")
        XCTAssertFalse(a.engine.hasUnsentWork)
    }

    // MARK: j — an upload that creates its meeting

    private func audioFile(_ name: String = "recording.m4a") throws -> URL {
        let url = hub.dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data("not really audio".utf8).write(to: url)
        return url
    }

    private func upload(_ request: URLRequest, file: URL) async throws -> (AudioTrackInfo?, Int) {
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (try? jsonDecoder.decode(AudioTrackInfo.self, from: data), status)
    }

    func testAnUploadCreatesItsMeetingAndASecondOneIsHarmless() async throws {
        let client = try await hub.client()
        let id = UUID()
        let file = try audioFile()
        let creating = CreateMeetingRequest(projectID: inboxID, title: "Standup", startedAt: Date(),
                                            durationSeconds: 61, source: .live)
        let request = try client.uploadRequest(id, kind: .imported, file: file, creating: creating)

        let (track, status) = try await upload(request, file: file)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(track?.kind, .imported)
        XCTAssertEqual(track?.sha256, try HubClient.sha256(of: file))
        let detail = try await client.meeting(id)
        XCTAssertEqual(detail.meeting.title, "Standup")
        XCTAssertEqual(detail.meeting.projectID, inboxID)
        XCTAssertEqual(detail.meeting.durationSeconds, 61)
        XCTAssertEqual(detail.audio.count, 1)

        let (_, again) = try await upload(request, file: file)
        XCTAssertEqual(again, 200)
        let meetings = try await MeetingModel.query(on: hub.app.db).count()
        XCTAssertEqual(meetings, 1)
        let tracks = try await client.audio(id)
        XCTAssertEqual(tracks.count, 1)
    }

    func testAnUploadForAProjectTheHubDoesNotHaveLandsInTheInbox() async throws {
        let client = try await hub.client()
        let id = UUID()
        let file = try audioFile()
        let creating = CreateMeetingRequest(projectID: UUID(), title: "Orphan", startedAt: Date(),
                                            durationSeconds: 5, source: .live)
        let (_, status) = try await upload(try client.uploadRequest(id, kind: .imported, file: file, creating: creating), file: file)
        XCTAssertEqual(status, 200)
        let detail = try await client.meeting(id)
        XCTAssertEqual(detail.meeting.projectID, inboxID)
    }

    func testAnUploadForADeletedMeetingIsRefused() async throws {
        let client = try await hub.client()
        let id = try await client.createMeeting(CreateMeetingRequest(
            projectID: inboxID, title: "Gone", startedAt: Date(), durationSeconds: 0, source: .live)).id
        try await client.deleteMeeting(id)
        let file = try audioFile()
        let creating = CreateMeetingRequest(projectID: inboxID, title: "Gone", startedAt: Date(), durationSeconds: 0, source: .live)
        let (_, status) = try await upload(try client.uploadRequest(id, kind: .imported, file: file, creating: creating), file: file)
        XCTAssertEqual(status, 410)
    }

    func testAnUploadWithABadChecksumIsRefused() async throws {
        let client = try await hub.client()
        let file = try audioFile()
        let creating = CreateMeetingRequest(projectID: inboxID, title: "x", startedAt: Date(), durationSeconds: 0, source: .live)
        var request = try client.uploadRequest(UUID(), kind: .imported, file: file, creating: creating)
        request.setValue(String(repeating: "0", count: 64), forHTTPHeaderField: HubAPI.checksumHeader)
        let (_, status) = try await upload(request, file: file)
        XCTAssertEqual(status, 400)
    }

    func testAnUploadThatAsksForProcessingQueuesAJob() async throws {
        let client = try await hub.client()
        let id = UUID()
        let file = try audioFile()
        let creating = CreateMeetingRequest(projectID: inboxID, title: "Standup", startedAt: Date(), durationSeconds: 5, source: .live)
        let request = try client.uploadRequest(id, kind: .imported, file: file, creating: creating, process: JobStep.allCases)
        let (_, status) = try await upload(request, file: file)
        XCTAssertEqual(status, 200)
        let job = try await client.job(id)
        XCTAssertEqual(job.steps, JobStep.allCases)
        XCTAssertEqual(job.status, .queued)
        let detail = try await client.meeting(id)
        XCTAssertEqual(detail.meeting.status, .queued)
    }

    func testARecordingUploadedBeforeItsDeviceSyncsEndsUpAsOneMeetingWithTheDevicesNotes() async throws {
        let a = try await device("phone"), b = try await device("mac")
        // The phone stops recording: the meeting exists locally and its upload is handed to the system.
        let projectID = a.createProject("Made offline")
        let id = a.createMeeting(in: projectID, title: "In the room")
        let local = try XCTUnwrap(a.meeting(id)).meeting
        let file = try audioFile()
        let creating = CreateMeetingRequest(projectID: local.projectID, title: local.title, titleIsAuto: local.titleIsAuto,
                                            startedAt: local.startedAt, durationSeconds: 90, source: .live)
        // The upload gets there first — before the phone has synced, so the hub doesn't know the project.
        let (_, status) = try await upload(try a.client.uploadRequest(id, kind: .imported, file: file, creating: creating), file: file)
        XCTAssertEqual(status, 200)
        // Meanwhile something happens to it on the hub, and notes are typed on the phone.
        _ = try await b.client.edit(id, MeetingEdit(addedItems: [ActionItem(task: "From the hub side")]))
        a.edit(id) { $0.notes = "typed on the phone" }

        try await a.sync()
        try await b.sync()

        let meetings = try await MeetingModel.query(on: hub.app.db).count()
        XCTAssertEqual(meetings, 1)
        let row = try await hub.meetingRow(id)
        XCTAssertEqual(row?.notes, "typed on the phone")
        XCTAssertEqual(row?.$project.id, projectID, "the sync moves it out of the Inbox to the project it was made in")
        for device in [a, b] {
            let record = try XCTUnwrap(device.meeting(id))
            XCTAssertEqual(record.notes, "typed on the phone")
            XCTAssertEqual(record.meeting.projectID, projectID)
            XCTAssertEqual(record.meeting.actionItems.map(\.task), ["From the hub side"])
            XCTAssertEqual(record.meeting.durationSeconds, 90)
        }
        XCTAssertFalse(a.engine.hasUnsentWork)
    }

    func testARecordingFiledInTheInboxIsMovedEvenWhenTheDeviceHearsBeforeItSpeaks() async throws {
        // The same race the other way round: the hub's event reaches the phone, which pulls before it pushes.
        let a = try await device("phone")
        let projectID = a.createProject("Made offline")
        let id = a.createMeeting(in: projectID, title: "In the room", notes: "typed first")
        let file = try audioFile()
        let creating = CreateMeetingRequest(projectID: projectID, title: "In the room", titleIsAuto: false,
                                            startedAt: Date(), durationSeconds: 30, source: .live)
        let (_, status) = try await upload(try a.client.uploadRequest(id, kind: .imported, file: file, creating: creating), file: file)
        XCTAssertEqual(status, 200)

        try await a.pull()
        XCTAssertEqual(a.meeting(id)?.meeting.projectID, projectID, "still where it was made, not where the hub filed it")
        XCTAssertEqual(a.meeting(id)?.notes, "typed first")
        XCTAssertTrue(a.engine.hasUnsentWork)
        try await a.sync()

        let row = try await hub.meetingRow(id)
        XCTAssertEqual(row?.$project.id, projectID)
        XCTAssertEqual(row?.notes, "typed first")
        XCTAssertFalse(a.engine.hasUnsentWork)
    }

    func testUnsentWorkSurvivesARelaunch() async throws {
        let a = try await device("a")
        let id = a.createMeeting(in: inboxID, title: "Weekly")
        try await a.sync()
        a.edit(id) { $0.notes = "typed, then the app was closed" }
        a.engine.save()

        let ledger = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: hub.dir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("ledger-a-") })
        let relaunched = SyncEngine(replica: a.replica, ledgerURL: ledger)
        XCTAssertTrue(relaunched.hasUnsentWork)
        try await relaunched.push(with: a.client)
        XCTAssertFalse(relaunched.hasUnsentWork)
        let row = try await hub.meetingRow(id)
        XCTAssertEqual(row?.notes, "typed, then the app was closed")
    }

    // MARK: k — transcripts and summaries

    func testContentTagFollowsTheTranscriptAndSummaryAndContentIsFetchedOncePerTag() async throws {
        let a = try await device("a"), b = try await device("b")
        let id = try await sharedMeeting(a, b)
        XCTAssertNil(b.meeting(id)?.contentTag)
        try await b.engine.fetchContent(with: b.client)
        XCTAssertEqual(b.replica.contentWrites, 0)

        _ = try await a.client.pushTranscript(id, [TranscriptSegment(speaker: "Speaker 1", start: 0, end: 2, text: "Hello there")])
        try await b.pull()
        let afterTranscript = try XCTUnwrap(b.meeting(id)?.contentTag)

        try await b.engine.fetchContent(with: b.client)
        XCTAssertEqual(b.replica.contentWrites, 1)
        XCTAssertEqual(b.replica.transcripts[id]?.map(\.text), ["Hello there"])
        XCTAssertNil(b.replica.summaries[id])

        try await Task.sleep(nanoseconds: 20_000_000)   // the tag is in milliseconds
        _ = try await a.client.pushSummary(id, markdown: "## Overview\n\nWe said hello.")
        try await b.pull()
        let afterSummary = try XCTUnwrap(b.meeting(id)?.contentTag)
        XCTAssertNotEqual(afterSummary, afterTranscript)

        try await b.engine.fetchContent(with: b.client)
        XCTAssertEqual(b.replica.contentWrites, 2)
        XCTAssertEqual(b.replica.summaries[id], "## Overview\n\nWe said hello.")

        // Unrelated changes don't move the tag, and nothing is fetched again.
        a.edit(id) { $0.notes = "a note" }
        try await a.sync()
        try await b.sync()
        XCTAssertEqual(b.meeting(id)?.contentTag, afterSummary)
        try await b.engine.fetchContent(with: b.client)
        XCTAssertEqual(b.replica.contentWrites, 2)
    }

    func testContentHeldLocallySurvivesAnEngineRestart() async throws {
        let a = try await device("a")
        let id = a.createMeeting(in: inboxID, title: "Weekly")
        try await a.sync()
        _ = try await a.client.pushTranscript(id, [TranscriptSegment(speaker: "Speaker 1", start: 0, end: 2, text: "Hi")])
        try await a.pull()
        try await a.engine.fetchContent(with: a.client)
        XCTAssertEqual(a.replica.contentWrites, 1)
        a.engine.save()
        // The ledger on disk is what a relaunch starts from.
        let ledger = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: hub.dir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("ledger-a-") })
        let relaunched = SyncEngine(replica: a.replica, ledgerURL: ledger)
        relaunched.use(workspace: hub.workspaceID)
        XCTAssertTrue(relaunched.tracks(meeting: id))
        try await relaunched.pull(with: a.client)
        try await relaunched.fetchContent(with: a.client)
        XCTAssertEqual(a.replica.contentWrites, 1)
    }

    // MARK: l — pairing another device

    func testAPairedDeviceCanPairAnother() async throws {
        let client = try await hub.client()
        let code = try await client.pairDevice(named: "Bobby's iPhone")
        XCTAssertTrue(code.token.hasPrefix("mh_"))
        let phone = HubClient(baseURL: hub.baseURL, token: code.token)
        let me = try await phone.me()
        XCTAssertEqual(me.device, "Bobby's iPhone")
        XCTAssertEqual(me.workspace.id, hub.workspaceID)
        XCTAssertEqual(PairingCode(url: try XCTUnwrap(code.url)), code)

        do {
            _ = try await HubClient(baseURL: hub.baseURL, token: "mh_wrong").me()
            XCTFail("a made-up token was accepted")
        } catch let error as HubClientError {
            XCTAssertTrue(error.isUnauthorized)
        }
    }

    // MARK: n — old clients

    func testLegacyWritesStillShowUpInTheFeed() async throws {
        let client = try await hub.client()
        let id = try await client.createMeeting(CreateMeetingRequest(
            projectID: inboxID, title: "Weekly", startedAt: Date(), durationSeconds: 0, source: .live)).id
        var cursor = try await client.changes(since: 0).revision

        _ = try await client.replaceActionItems(id, [ActionItem(task: "One"), ActionItem(task: "Two")])
        var changes = try await client.changes(since: cursor)
        XCTAssertEqual(changes.meetings.map(\.id), [id])
        XCTAssertEqual(changes.meetings.first?.meeting.actionItems.map(\.task), ["One", "Two"])
        XCTAssertGreaterThan(changes.revision, cursor)
        cursor = changes.revision

        _ = try await client.patchMeeting(id, PatchMeetingRequest(notes: "from an old client"))
        changes = try await client.changes(since: cursor)
        XCTAssertEqual(changes.meetings.first?.notes, "from an old client")
        XCTAssertGreaterThan(changes.revision, cursor)
        cursor = changes.revision

        // The case the old `touch` existed for: a write that changes only a child row.
        let itemID = try XCTUnwrap(changes.meetings.first?.meeting.actionItems.first?.id)
        var request = URLRequest(url: hub.baseURL.appendingPathComponent("api/v1/meetings/\(id.uuidString)/action-items/\(itemID.uuidString)"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(client.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try wireEncoder.encode(PatchActionItemRequest(done: true))
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        changes = try await client.changes(since: cursor)
        XCTAssertEqual(changes.meetings.first?.meeting.actionItems.first?.done, true)
        cursor = changes.revision

        // And the old pull-by-time still answers.
        let listed = try await client.meetings(since: Date().addingTimeInterval(-60))
        XCTAssertEqual(listed.map(\.id), [id])

        try await client.deleteMeeting(id)
        changes = try await client.changes(since: cursor)
        XCTAssertEqual(changes.removed, [Tombstone(kind: .meeting, id: id)])
        XCTAssertTrue(changes.meetings.isEmpty)
    }

    // MARK: Edits the hub guards

    func testAnEditCannotRollBackWhatBelongsToTheHub() async throws {
        let client = try await hub.client()
        var item = ActionItem(task: "Send deck")
        let id = try await client.createMeeting(CreateMeetingRequest(
            projectID: inboxID, title: "Weekly", startedAt: Date(), durationSeconds: 0, source: .live)).id
        _ = try await client.replaceActionItems(id, [item])
        let found = try await ActionItemModel.find(item.id, on: hub.app.db)
        let row = try XCTUnwrap(found)
        row.guidance = "the hub's advice"
        row.sourceQuote = "what was said"
        try await row.save(on: hub.app.db)

        item.done = true
        item.guidance = "stale advice from a device"
        let reply = try await client.edit(id, MeetingEdit(changedItems: [item]))
        XCTAssertEqual(reply.meeting.actionItems.first?.done, true)
        XCTAssertEqual(reply.meeting.actionItems.first?.guidance, "the hub's advice")
        XCTAssertEqual(reply.meeting.actionItems.first?.sourceQuote, "what was said")
    }

    func testAChangeToAnItemTheHubRemovedDoesNotBringItBackButAnAddedOneIsIdempotent() async throws {
        let client = try await hub.client()
        let id = try await client.createMeeting(CreateMeetingRequest(
            projectID: inboxID, title: "Weekly", startedAt: Date(), durationSeconds: 0, source: .live)).id
        var ghost = ActionItem(task: "Never on the hub")
        ghost.done = true
        var reply = try await client.edit(id, MeetingEdit(changedItems: [ghost]))
        XCTAssertTrue(reply.meeting.actionItems.isEmpty)

        var added = ActionItem(task: "Added", isManual: true)
        reply = try await client.edit(id, MeetingEdit(addedItems: [added]))
        XCTAssertEqual(reply.meeting.actionItems.map(\.task), ["Added"])
        added.done = true
        reply = try await client.edit(id, MeetingEdit(addedItems: [added]))   // the same add, resent after a lost reply
        XCTAssertEqual(reply.meeting.actionItems.count, 1)
        XCTAssertEqual(reply.meeting.actionItems.first?.done, true)

        reply = try await client.edit(id, MeetingEdit(removedItems: [added.id, UUID()]))
        XCTAssertTrue(reply.meeting.actionItems.isEmpty)
    }

    func testEventStateIsEditablePerEvent() async throws {
        let a = try await device("a"), b = try await device("b")
        let id = try await sharedMeeting(a, b)
        let zone = TimeZone(identifier: "UTC")!
        let events = [MeetingEvent(title: "Demo", start: EventDate(date: Date(timeIntervalSince1970: 1_790_000_000), hasTime: true, timeZone: zone)),
                      MeetingEvent(title: "Launch", start: EventDate(date: Date(timeIntervalSince1970: 1_791_000_000), hasTime: false, timeZone: zone))]
        _ = try await a.client.patchMeeting(id, PatchMeetingRequest(events: events))
        try await a.sync()
        try await b.sync()

        a.edit(id) { $0.meeting.events[0].dismissed = true }
        b.edit(id) { $0.meeting.events[1].addedAt = Date(timeIntervalSince1970: 1_781_000_000) }
        try await a.sync()
        try await b.sync()
        try await a.sync()

        for device in [a, b] {
            let merged = try XCTUnwrap(device.meeting(id)).meeting.events
            XCTAssertEqual(merged.map(\.dismissed), [true, false])
            XCTAssertEqual(merged.map { $0.addedAt != nil }, [false, true])
            XCTAssertFalse(device.engine.hasUnsentWork)
        }
    }

    func testMovingAMeetingAndRenamingSpeakersAndProjects() async throws {
        let a = try await device("a"), b = try await device("b")
        let id = try await sharedMeeting(a, b)
        let projectID = a.createProject("Launch")
        a.edit(id) { $0.meeting.projectID = projectID; $0.meeting.speakerNames["Speaker 1"] = "Ann" }
        b.edit(id) { $0.meeting.speakerNames["Speaker 2"] = "Bo" }
        try await a.sync()
        try await b.sync()
        try await a.sync()
        for device in [a, b] {
            XCTAssertEqual(device.meeting(id)?.meeting.projectID, projectID)
            XCTAssertEqual(device.meeting(id)?.meeting.speakerNames, ["Speaker 1": "Ann", "Speaker 2": "Bo"])
        }

        // Clearing a name is an edit like any other, and leaves the other speaker's alone.
        b.edit(id) { $0.meeting.speakerNames["Speaker 1"] = nil }
        try await b.sync()
        try await a.sync()
        for device in [a, b] {
            XCTAssertEqual(device.meeting(id)?.meeting.speakerNames, ["Speaker 2": "Bo"])
            XCTAssertFalse(device.engine.hasUnsentWork)
        }

        a.editProject(projectID) { $0.project.name = "Launch 2027" }
        b.editProject(projectID) { $0.context = "B's context" }
        try await a.sync()
        try await b.sync()
        try await a.sync()
        for device in [a, b] {
            XCTAssertEqual(device.replica.projects[projectID]?.project.name, "Launch 2027")
            XCTAssertEqual(device.replica.projects[projectID]?.context, "B's context")
            XCTAssertFalse(device.engine.hasUnsentWork)
        }
    }

    func testAMeetingTheHubWasNeverToldAboutStaysLocal() async throws {
        let a = try await device("a")
        let id = UUID()
        a.replica.meetings[id] = MeetingRecord(meeting: Meeting(id: id, projectID: inboxID, title: "Private"))
        a.engine.note(.meeting(id))
        a.engine.note(.removedMeeting(id))
        XCTAssertFalse(a.engine.hasUnsentWork)
        try await a.sync()
        let count = try await MeetingModel.query(on: hub.app.db).count()
        XCTAssertEqual(count, 0)
    }

    func testPairingWithAnotherWorkspaceStartsTheLedgerOver() async throws {
        let a = try await device("a")
        let id = a.createMeeting(in: inboxID, title: "Weekly")
        try await a.sync()
        XCTAssertTrue(a.engine.tracks(meeting: id))
        a.engine.use(workspace: hub.workspaceID)
        XCTAssertTrue(a.engine.tracks(meeting: id))
        a.engine.use(workspace: UUID())
        XCTAssertFalse(a.engine.tracks(meeting: id))
    }
}

@MainActor
private final class Progress {
    var finished = false
}
