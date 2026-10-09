import XCTest
import MeetingCore
@testable import MeetingSync

/// The rules in `SyncMerge`, one at a time, with no hub involved.
final class SyncMergeTests: XCTestCase {
    private let projectID = UUID()
    private let otherProjectID = UUID()

    private func record(title: String = "Weekly", titleIsAuto: Bool = false, notes: String = "",
                        items: [ActionItem] = [], events: [MeetingEvent] = [],
                        speakers: [String: String] = [:], status: MeetingStatus = .ready,
                        id: UUID = UUID()) -> MeetingRecord {
        MeetingRecord(meeting: Meeting(id: id, projectID: projectID, title: title, titleIsAuto: titleIsAuto,
                                       startedAt: Date(timeIntervalSince1970: 1_780_000_000), status: status,
                                       actionItems: items, events: events, speakerNames: speakers),
                      notes: notes)
    }

    private func project(_ name: String = "Alpha", context: String = "", learned: String = "", id: UUID = UUID()) -> ProjectDetail {
        ProjectDetail(project: Project(id: id, name: name, createdAt: Date(timeIntervalSince1970: 1_780_000_000)),
                      context: context, learnedContext: learned, meetingCount: 0)
    }

    private func event(_ title: String, at seconds: TimeInterval = 1_790_000_000) -> MeetingEvent {
        MeetingEvent(title: title, start: EventDate(date: Date(timeIntervalSince1970: seconds), hasTime: true,
                                                    timeZone: TimeZone(identifier: "UTC")!))
    }

    // MARK: - pick

    func testPickKeepsLocalOnlyWhereItChanged() {
        XCTAssertEqual(SyncMerge.pick("a", "a", "b"), "b")
        XCTAssertEqual(SyncMerge.pick("a", "c", "b"), "c")
        XCTAssertEqual(SyncMerge.pick("a", "a", "a"), "a")
    }

    // MARK: - Projects

    func testProjectTakesRemoteWhereLocalIsUnchanged() {
        let base = project("Alpha", context: "ctx", learned: "old")
        var remote = base
        remote.project.name = "Alpha 2"
        remote.learnedContext = "new"
        remote.meetingCount = 7
        let merged = SyncMerge.project(base: base, local: base, remote: remote)
        XCTAssertEqual(merged.project.name, "Alpha 2")
        XCTAssertEqual(merged.learnedContext, "new")
        XCTAssertEqual(merged.meetingCount, 7)
    }

    func testProjectKeepsEachLocalChangeAndTakesTheRest() {
        let base = project("Alpha", context: "ctx", learned: "old")
        var local = base
        local.context = "my notes"
        var remote = base
        remote.project.name = "Renamed elsewhere"
        remote.context = "their notes"
        remote.learnedContext = "new"
        let merged = SyncMerge.project(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.project.name, "Renamed elsewhere")
        XCTAssertEqual(merged.context, "my notes")
        XCTAssertEqual(merged.learnedContext, "new")
    }

    func testProjectPatchHoldsOnlyWhatChanged() {
        let base = project("Alpha", context: "ctx", learned: "old")
        XCTAssertNil(PatchProjectRequest(from: base, to: base))

        var local = base
        local.context = "new ctx"
        local.meetingCount = 99   // bookkeeping, not an edit
        let patch = PatchProjectRequest(from: base, to: local)
        XCTAssertNil(patch?.name)
        XCTAssertEqual(patch?.context, "new ctx")
        XCTAssertNil(patch?.learnedContext)

        local.project.name = "Beta"
        local.learnedContext = ""
        let full = PatchProjectRequest(from: base, to: local)
        XCTAssertEqual(full?.name, "Beta")
        XCTAssertEqual(full?.learnedContext, "")
    }

    func testSameProjectIgnoresBookkeeping() {
        let a = project("Alpha")
        var b = a
        b.meetingCount = 5
        b.project.updatedAt = Date()
        XCTAssertTrue(SyncMerge.same(a, b))
        b.context = "x"
        XCTAssertFalse(SyncMerge.same(a, b))
    }

    // MARK: - Meeting fields

    func testMeetingFieldsEditedOnDifferentDevicesBothSurvive() {
        let base = record(title: "Weekly", notes: "")
        var local = base
        local.notes = "my notes"
        var remote = base
        remote.meeting.title = "Weekly sync"
        let merged = SyncMerge.meeting(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.meeting.title, "Weekly sync")
        XCTAssertEqual(merged.notes, "my notes")
    }

    func testLocalWinsWhereBothChangedTheSameField() {
        let base = record(notes: "a")
        var local = base, remote = base
        local.notes = "mine"
        remote.notes = "theirs"
        XCTAssertEqual(SyncMerge.meeting(base: base, local: local, remote: remote).notes, "mine")
    }

    func testHubOwnedFieldsAlwaysComeFromRemote() {
        let base = record(status: .queued)
        var local = base
        local.meeting.status = .uploading
        local.meeting.errorMessage = "local only"
        local.meeting.durationSeconds = 1
        local.contentTag = nil
        var remote = base
        remote.meeting.status = .ready
        remote.meeting.errorMessage = nil
        remote.meeting.durationSeconds = 1800
        remote.contentTag = "1-2"
        let merged = SyncMerge.meeting(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.meeting.status, .ready)
        XCTAssertNil(merged.meeting.errorMessage)
        XCTAssertEqual(merged.meeting.durationSeconds, 1800)
        XCTAssertEqual(merged.contentTag, "1-2")
    }

    func testTitleAndTitleIsAutoTravelTogether() {
        // The hub auto-titles; nobody typed anything here: take both from the hub.
        let base = record(title: "Meeting", titleIsAuto: true)
        var remote = base
        remote.meeting.title = "Roadmap review"
        var merged = SyncMerge.meeting(base: base, local: base, remote: remote)
        XCTAssertEqual(merged.meeting.title, "Roadmap review")
        XCTAssertTrue(merged.meeting.titleIsAuto)

        // Typed here while the hub auto-titled: the typed title stands, and stays marked as typed.
        var local = base
        local.meeting.title = "My title"
        local.meeting.titleIsAuto = false
        merged = SyncMerge.meeting(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.meeting.title, "My title")
        XCTAssertFalse(merged.meeting.titleIsAuto)
    }

    func testProjectMoveIsKeptOrTaken() {
        let base = record()
        var local = base
        local.meeting.projectID = otherProjectID
        XCTAssertEqual(SyncMerge.meeting(base: base, local: local, remote: base).meeting.projectID, otherProjectID)
        var remote = base
        remote.meeting.projectID = otherProjectID
        XCTAssertEqual(SyncMerge.meeting(base: base, local: base, remote: remote).meeting.projectID, otherProjectID)
    }

    // MARK: - Speaker names

    func testSpeakerNamesMergePerSpeaker() {
        let base = ["Speaker 1": "Ann", "Speaker 3": "Old"]
        let local = ["Speaker 1": "Anna", "Speaker 3": "Old"]                      // renamed 1
        let remote = ["Speaker 1": "Ann", "Speaker 2": "Bo"]                       // named 2, cleared 3
        XCTAssertEqual(SyncMerge.speakerNames(base: base, local: local, remote: remote),
                       ["Speaker 1": "Anna", "Speaker 2": "Bo"])
    }

    func testSpeakerNameClearedLocallyStaysCleared() {
        let base = ["Speaker 1": "Ann"]
        XCTAssertEqual(SyncMerge.speakerNames(base: base, local: [:], remote: base), [:])
    }

    // MARK: - Action items

    func testItemEditedLocallyKeepsItsEditablePartAndTakesHubOwnedPart() {
        let was = ActionItem(task: "Send deck", owner: "Ann")
        var mine = was
        mine.done = true
        var theirs = was
        theirs.owner = "Bo"                  // an edit elsewhere to the same item: local wins the whole editable part
        theirs.guidance = "Start with the outline."
        theirs.sourceQuote = "Ann will send the deck"
        let merged = SyncMerge.actionItems(base: [was], local: [mine], remote: [theirs])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].done)
        XCTAssertEqual(merged[0].owner, "Ann")
        XCTAssertEqual(merged[0].guidance, "Start with the outline.")
        XCTAssertEqual(merged[0].sourceQuote, "Ann will send the deck")
    }

    func testItemUntouchedLocallyTakesTheHubsCopy() {
        let was = ActionItem(task: "Send deck")
        var theirs = was
        theirs.done = true
        theirs.task = "Send the deck"
        XCTAssertEqual(SyncMerge.actionItems(base: [was], local: [was], remote: [theirs]), [theirs])
    }

    func testStaleLocalGuidanceNeverOverridesTheHubs() {
        var was = ActionItem(task: "Send deck")
        was.guidance = "old advice"
        var mine = was
        mine.done = true
        var theirs = was
        theirs.guidance = "new advice"
        XCTAssertEqual(SyncMerge.actionItems(base: [was], local: [mine], remote: [theirs])[0].guidance, "new advice")
    }

    func testItemRemovedLocallyStaysOut() {
        let a = ActionItem(task: "A"), b = ActionItem(task: "B")
        let merged = SyncMerge.actionItems(base: [a, b], local: [b], remote: [a, b])
        XCTAssertEqual(merged.map(\.id), [b.id])
    }

    func testItemAddedLocallyIsKeptAtTheEnd() {
        let a = ActionItem(task: "A"), fromHub = ActionItem(task: "From the hub")
        let mine = ActionItem(task: "Mine", isManual: true)
        let merged = SyncMerge.actionItems(base: [a], local: [mine, a], remote: [a, fromHub])
        XCTAssertEqual(merged.map(\.id), [a.id, fromHub.id, mine.id])
    }

    func testItemRemovedOnTheHubIsDroppedEvenIfEditedLocally() {
        let a = ActionItem(task: "A"), b = ActionItem(task: "B")
        var editedB = b
        editedB.done = true
        let merged = SyncMerge.actionItems(base: [a, b], local: [a, editedB], remote: [a])
        XCTAssertEqual(merged.map(\.id), [a.id])
    }

    func testItemOnBothSidesButNotInBaseKeepsLocalsEditablePart() {
        // Added here, sent, reply lost — then edited again before the hub's copy came back in the feed.
        var theirs = ActionItem(task: "Book room", isManual: true)
        theirs.guidance = "from the hub"
        var mine = theirs
        mine.guidance = nil
        mine.task = "Book the big room"
        mine.done = true
        let merged = SyncMerge.actionItems(base: [], local: [mine], remote: [theirs])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].task, "Book the big room")
        XCTAssertTrue(merged[0].done)
        XCTAssertEqual(merged[0].guidance, "from the hub")
    }

    func testItemsFollowTheHubsOrder() {
        let a = ActionItem(task: "A"), b = ActionItem(task: "B"), c = ActionItem(task: "C")
        let merged = SyncMerge.actionItems(base: [a, b, c], local: [a, b, c], remote: [c, a, b])
        XCTAssertEqual(merged.map(\.id), [c.id, a.id, b.id])
    }

    // MARK: - Events

    func testEventStateIsMergedAndEverythingElseIsTheHubs() {
        let was = event("Demo")
        var mine = was
        mine.dismissed = true
        mine.title = "Local title that must not win"
        var theirs = was
        theirs.start = EventDate(date: Date(timeIntervalSince1970: 1_795_000_000), hasTime: true, timeZone: TimeZone(identifier: "UTC")!)
        theirs.addedAt = Date(timeIntervalSince1970: 1_781_000_000)
        let merged = SyncMerge.events(base: [was], local: [mine], remote: [theirs])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].dismissed)
        XCTAssertEqual(merged[0].addedAt, theirs.addedAt)
        XCTAssertEqual(merged[0].start, theirs.start)
        XCTAssertEqual(merged[0].title, "Demo")
    }

    func testEventsTheHubDroppedOrAddedFollowTheHub() {
        let kept = event("Kept"), dropped = event("Dropped"), new = event("New")
        var mineDropped = dropped
        mineDropped.dismissed = true
        let merged = SyncMerge.events(base: [kept, dropped], local: [kept, mineDropped], remote: [new, kept])
        XCTAssertEqual(merged.map(\.id), [new.id, kept.id])
    }

    // MARK: - Diff

    func testEditIsEmptyWhenNothingEditableDiffers() {
        var item = ActionItem(task: "A")
        let ev = event("Demo")
        let base = record(items: [item], events: [ev])
        var local = base
        local.meeting.updatedAt = Date()
        local.meeting.status = .failed
        local.meeting.errorMessage = "x"
        local.meeting.durationSeconds = 5
        local.contentTag = "t"
        item.guidance = "advice"
        item.guidanceAt = Date()
        item.sourceQuote = "quote"
        item.lastDiscussedMeetingID = UUID()
        local.meeting.actionItems = [item]
        local.meeting.events[0].title = "Renamed locally"
        XCTAssertTrue(MeetingEdit(from: base, to: local).isEmpty)
        XCTAssertTrue(SyncMerge.same(base, { var r = base; r.meeting.updatedAt = Date(); r.contentTag = "z"; return r }()))
    }

    func testEditCarriesEachChangedField() {
        let base = record(title: "Weekly", titleIsAuto: true, notes: "", speakers: ["Speaker 1": "Ann"])
        var local = base
        local.meeting.title = "Planning"
        local.meeting.titleIsAuto = false
        local.meeting.projectID = otherProjectID
        local.notes = "notes"
        local.meeting.speakerNames["Speaker 2"] = "Bo"
        let edit = MeetingEdit(from: base, to: local)
        XCTAssertEqual(edit.title, "Planning")
        XCTAssertEqual(edit.titleIsAuto, false)
        XCTAssertEqual(edit.projectID, otherProjectID)
        XCTAssertEqual(edit.notes, "notes")
        XCTAssertEqual(edit.speakerNames, ["Speaker 2": "Bo"], "only the speaker that was renamed")
        XCTAssertTrue(edit.addedItems.isEmpty && edit.changedItems.isEmpty && edit.removedItems.isEmpty && edit.changedEvents.isEmpty)
    }

    func testEditSendsAClearedSpeakerNameAsEmpty() {
        let base = record(speakers: ["Speaker 1": "Ann", "Speaker 2": "Bo"])
        var local = base
        local.meeting.speakerNames["Speaker 1"] = nil
        local.meeting.speakerNames["Speaker 2"] = "Bob"
        XCTAssertEqual(MeetingEdit(from: base, to: local).speakerNames, ["Speaker 1": "", "Speaker 2": "Bob"])
    }

    func testEditSendsTitleIsAutoAloneWhenOnlyTheFlagChanged() {
        let base = record(title: "Weekly", titleIsAuto: true)
        var local = base
        local.meeting.titleIsAuto = false
        let edit = MeetingEdit(from: base, to: local)
        XCTAssertNil(edit.title)
        XCTAssertEqual(edit.titleIsAuto, false)
    }

    func testEditSortsItemsIntoAddedChangedRemoved() {
        let kept = ActionItem(task: "Kept"), changed = ActionItem(task: "Changed"), removed = ActionItem(task: "Removed")
        let base = record(items: [kept, changed, removed])
        var local = base
        var edited = changed
        edited.done = true
        let added = ActionItem(task: "Added", isManual: true)
        local.meeting.actionItems = [kept, edited, added]
        let edit = MeetingEdit(from: base, to: local)
        XCTAssertEqual(edit.addedItems.map(\.id), [added.id])
        XCTAssertEqual(edit.changedItems.map(\.id), [changed.id])
        XCTAssertEqual(edit.removedItems, [removed.id])
    }

    func testEditCarriesOnlyEventsWhoseStateChanged() {
        let a = event("A"), b = event("B")
        let base = record(events: [a, b])
        var local = base
        local.meeting.events[1].addedAt = Date(timeIntervalSince1970: 1_781_000_000)
        local.meeting.events.append(event("Not from the hub"))
        let edit = MeetingEdit(from: base, to: local)
        XCTAssertEqual(edit.changedEvents.map(\.id), [b.id])
    }

    func testMergeThenDiffLeavesOnlyTheLocalChange() {
        // The round trip the engine relies on: after merging the hub's copy, what is left to send is exactly
        // what this device changed — never the hub's own changes sent back at it.
        let item = ActionItem(task: "A")
        let base = record(title: "Weekly", notes: "", items: [item])
        var local = base
        local.notes = "mine"
        var remote = base
        remote.meeting.title = "Renamed elsewhere"
        remote.meeting.actionItems[0].done = true
        remote.meeting.actionItems.append(ActionItem(task: "From elsewhere"))
        let merged = SyncMerge.meeting(base: base, local: local, remote: remote)
        XCTAssertEqual(MeetingEdit(from: remote, to: merged), MeetingEdit(notes: "mine"))
    }

    func testMeetingEditDecodesWithMissingLists() throws {
        let edit = try jsonDecoder.decode(MeetingEdit.self, from: Data(#"{"notes":"n"}"#.utf8))
        XCTAssertEqual(edit, MeetingEdit(notes: "n"))
        XCTAssertTrue(try jsonDecoder.decode(MeetingEdit.self, from: Data("{}".utf8)).isEmpty)
    }
}
