import Foundation
import MeetingCore

/// A device's own copy of the data, as far as syncing needs to see it. The Mac keeps a folder of Markdown, a
/// phone keeps a cache; both look the same from here.
///
/// The `apply` and `discard` calls carry what the hub said. They are not edits made on this device, and the
/// engine ignores any change notification they cause.
@MainActor
public protocol SyncReplica: AnyObject {
    func projectRecord(_ id: UUID) -> ProjectDetail?
    func meetingRecord(_ id: UUID) -> MeetingRecord?

    /// Create or overwrite.
    func apply(_ project: ProjectDetail)
    func apply(_ meeting: MeetingRecord)
    func applyContent(transcript: [TranscriptSegment], summary: String?, for meetingID: UUID)
    /// A project goes with the meetings in it.
    func discardProject(_ id: UUID)
    func discardMeeting(_ id: UUID)
}

/// Something that happened to the device's own copy, as told to the engine.
public enum LocalChange: Sendable {
    /// Created or edited. A project the hub hasn't heard of is sent to it; projects are just a name and notes.
    case project(UUID)
    case removedProject(UUID)
    /// A meeting made on this device that should now exist on the hub.
    case newMeeting(UUID)
    /// Edited. Ignored for a meeting the hub was never told about — that one is still this device's alone.
    case meeting(UUID)
    case removedMeeting(UUID)
}

/// Keeps a replica and the hub in step. See `SyncMerge` for the rule; this is the bookkeeping around it.
///
/// * `pull` reads the hub's change feed from where it left off and merges each change into the replica.
/// * `push` sends what the replica changed, one request per changed thing, and merges each reply the same way.
///
/// The two never overlap. A reply and a feed page each describe the hub at one moment, and applying them out of
/// order would let an older copy overwrite a newer one.
@MainActor
public final class SyncEngine {
    private let replica: any SyncReplica
    private let ledgerURL: URL
    private var ledger: SyncLedger
    /// Set while writing the hub's changes into the replica, so they aren't mistaken for local edits.
    private var applying = false
    private var fetchingContent = false
    private var queue: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    /// Called when a local change leaves something to send.
    public var onUnsentWork: (() -> Void)?

    public init(replica: any SyncReplica, ledgerURL: URL) {
        self.replica = replica
        self.ledgerURL = ledgerURL
        ledger = SyncLedger.load(from: ledgerURL)
    }

    public var hasUnsentWork: Bool { ledger.hasUnsentWork }

    /// True once the hub has this meeting (or has at least been asked to make it).
    public func tracks(meeting id: UUID) -> Bool { ledger.meetings[id] != nil }
    public func tracks(project id: UUID) -> Bool { ledger.projects[id] != nil }

    /// Everything in the ledger describes one workspace. Paired with another, it starts again from nothing.
    public func use(workspace id: UUID) {
        guard ledger.workspaceID != id else { return }
        ledger = SyncLedger(workspaceID: id)
        save()
    }

    /// Forget the hub entirely. The replica is left as it is.
    public func reset() {
        ledger = SyncLedger()
        save()
    }

    // MARK: - Local changes

    public func note(_ change: LocalChange) {
        guard !applying else { return }
        switch change {
        case .project(let id):
            if ledger.projects[id] == nil {
                guard let made = replica.projectRecord(id) else { return }
                ledger.projects[id] = made
                ledger.unsentProjects.insert(id)
            }
            ledger.dirtyProjects.insert(id)
        case .removedProject(let id):
            guard ledger.projects[id] != nil else { return }
            for (meetingID, record) in ledger.meetings where record.meeting.projectID == id { ledger.forget(meeting: meetingID) }
            ledger.forget(project: id)
            ledger.removedProjects.insert(id)
        case .newMeeting(let id):
            guard ledger.meetings[id] == nil, let made = replica.meetingRecord(id) else { return }
            ledger.meetings[id] = Self.asCreated(made)
            ledger.unsentMeetings.insert(id)
            ledger.dirtyMeetings.insert(id)
        case .meeting(let id):
            guard ledger.meetings[id] != nil else { return }
            ledger.dirtyMeetings.insert(id)
        case .removedMeeting(let id):
            guard ledger.meetings[id] != nil else { return }
            ledger.forget(meeting: id)
            ledger.removedMeetings.insert(id)
        }
        saveSoon()
        onUnsentWork?()
    }

    // MARK: - Pull

    public func pull(with client: HubClient) async throws {
        try await exclusively {
            var more = true
            while more {
                let changes = try await client.changes(since: self.ledger.cursor)
                for tombstone in changes.removed { self.bury(tombstone) }
                for project in changes.projects { self.absorb(project, base: self.ledger.projects[project.id]) }
                for meeting in changes.meetings {
                    var base = self.ledger.meetings[meeting.id]
                    if self.ledger.unsentMeetings.remove(meeting.id) != nil {
                        base = base.map { Self.asFiled($0, in: meeting.meeting.projectID) }
                    }
                    self.absorb(meeting, base: base)
                }
                self.ledger.cursor = changes.revision
                self.save()
                more = changes.hasMore
            }
        }
    }

    /// Bring the transcripts and summaries held locally up to date, newest meeting first. Not part of `pull`
    /// because it is the slow part, and nothing else has to wait for it.
    public func fetchContent(with client: HubClient) async throws {
        guard !fetchingContent else { return }
        fetchingContent = true
        defer { fetchingContent = false }
        let stale = ledger.meetings.values
            .filter { $0.contentTag != nil && $0.contentTag != ledger.contentTags[$0.id] }
            .sorted { $0.meeting.startedAt > $1.meeting.startedAt }
        for record in stale {
            do {
                let detail = try await client.meeting(record.id)
                guard ledger.meetings[record.id] != nil else { continue }
                whileApplying { replica.applyContent(transcript: detail.transcript, summary: detail.summaryMarkdown, for: record.id) }
                ledger.contentTags[record.id] = record.contentTag
                saveSoon()
            } catch let error as HubClientError where error.isNotFound {
                continue   // deleted in the meantime; the feed will say so
            }
        }
    }

    private func bury(_ tombstone: Tombstone) {
        switch tombstone.kind {
        case .meeting:
            ledger.removedMeetings.remove(tombstone.id)
            ledger.forget(meeting: tombstone.id)
            if replica.meetingRecord(tombstone.id) != nil { whileApplying { replica.discardMeeting(tombstone.id) } }
        case .project:
            ledger.removedProjects.remove(tombstone.id)
            ledger.forget(project: tombstone.id)
            if replica.projectRecord(tombstone.id) != nil { whileApplying { replica.discardProject(tombstone.id) } }
        }
    }

    // MARK: - Merging what the hub says

    /// Take the hub's copy. `base` is what this device's edits are measured against: the copy it last had from
    /// the hub when pulling, the copy it just sent when pushing. With no base there is nothing to measure
    /// against, and the hub's copy stands.
    private func absorb(_ remote: MeetingRecord, base: MeetingRecord?) {
        let id = remote.id
        guard !ledger.removedMeetings.contains(id) else { return }   // deleted here; the hub is about to hear
        let local = replica.meetingRecord(id)
        var merged = remote
        if let local, let base { merged = SyncMerge.meeting(base: base, local: local, remote: remote) }
        ledger.meetings[id] = remote
        if local.map({ !SyncMerge.same($0, merged) }) ?? true { whileApplying { replica.apply(merged) } }
        if MeetingEdit(from: remote, to: merged).isEmpty { ledger.dirtyMeetings.remove(id) } else { ledger.dirtyMeetings.insert(id) }
    }

    private func absorb(_ remote: ProjectDetail, base: ProjectDetail?) {
        let id = remote.id
        guard !ledger.removedProjects.contains(id) else { return }
        ledger.unsentProjects.remove(id)
        let local = replica.projectRecord(id)
        var merged = remote
        if let local, let base { merged = SyncMerge.project(base: base, local: local, remote: remote) }
        ledger.projects[id] = remote
        if local.map({ !SyncMerge.same($0, merged) }) ?? true { whileApplying { replica.apply(merged) } }
        if PatchProjectRequest(from: remote, to: merged) == nil { ledger.dirtyProjects.remove(id) } else { ledger.dirtyProjects.insert(id) }
    }

    // MARK: - Push

    /// Send everything this device changed. Stops at the first connectivity failure — the rest would fail the
    /// same way — but carries on past a change the hub refuses, which stays unsent and is logged.
    public func push(with client: HubClient) async throws {
        try await exclusively {
            defer { self.save() }
            try await self.each(self.ledger.removedMeetings) { id in
                try await Self.unlessMissing { try await client.deleteMeeting(id) }
                self.ledger.removedMeetings.remove(id)
            }
            try await self.each(self.ledger.removedProjects) { id in
                try await Self.unlessMissing { try await client.deleteProject(id) }
                self.ledger.removedProjects.remove(id)
            }
            // Projects first: a meeting can't be created in, or moved to, one the hub hasn't got.
            try await self.each(self.ledger.dirtyProjects) { try await self.push(project: $0, with: client) }
            try await self.each(self.ledger.dirtyMeetings) { try await self.push(meeting: $0, with: client) }
        }
    }

    private func each(_ ids: Set<UUID>, _ send: (UUID) async throws -> Void) async throws {
        for id in ids {
            do { try await send(id) }
            catch let error where error.isConnectivityProblem { throw error }
            catch { Log.hub.error("couldn't sync \(id.uuidString.prefix(8)): \(error.localizedDescription)") }
        }
    }

    /// The hub already not having something is as good as deleting it.
    private static func unlessMissing(_ request: () async throws -> Void) async throws {
        do { try await request() } catch let error as HubClientError where error.isNotFound {}
    }

    private func push(project id: UUID, with client: HubClient) async throws {
        guard let base = ledger.projects[id], replica.projectRecord(id) != nil else {
            ledger.dirtyProjects.remove(id)
            return
        }
        do {
            if ledger.unsentProjects.contains(id) {
                let made = try await client.createProject(CreateProjectRequest(
                    id: id, name: base.project.name, context: base.context, learnedContext: base.learnedContext))
                absorb(made, base: base)
            }
            guard let sent = replica.projectRecord(id), let base = ledger.projects[id],
                  let patch = PatchProjectRequest(from: base, to: sent) else {
                ledger.dirtyProjects.remove(id)
                return
            }
            absorb(try await client.patchProject(id, patch), base: sent)
        } catch let error as HubClientError where error.isGone {
            ledger.forget(project: id)
            whileApplying { replica.discardProject(id) }
        } catch let error as HubClientError where error.isNotFound {
            ledger.dirtyProjects.remove(id)   // deleted on the hub; its tombstone is in the feed
        }
    }

    private func push(meeting id: UUID, with client: HubClient) async throws {
        guard var base = ledger.meetings[id], let sent = replica.meetingRecord(id) else {
            ledger.dirtyMeetings.remove(id)
            return
        }
        do {
            if ledger.unsentMeetings.contains(id) {
                let m = base.meeting
                let made = try await client.createMeeting(CreateMeetingRequest(
                    id: id, projectID: m.projectID, title: m.title, titleIsAuto: m.titleIsAuto, startedAt: m.startedAt,
                    durationSeconds: m.durationSeconds, source: m.source, importedFileName: m.importedFileName))
                ledger.unsentMeetings.remove(id)
                base = Self.asFiled(base, in: made.projectID)
                ledger.meetings[id] = base
            }
            let edit = MeetingEdit(from: base, to: sent)
            guard !edit.isEmpty else {
                ledger.dirtyMeetings.remove(id)
                return
            }
            absorb(try await client.edit(id, edit), base: sent)
        } catch let error as HubClientError where error.isGone {
            ledger.forget(meeting: id)
            whileApplying { replica.discardMeeting(id) }
        } catch let error as HubClientError where error.isNotFound {
            ledger.dirtyMeetings.remove(id)
        }
    }

    /// A meeting made here, as the hub will hold it once it has been created there. Creating one sends its
    /// title, time and project and nothing more, so anything else it already has — notes, action items,
    /// speaker names — must still count as a change to send.
    private static func asCreated(_ record: MeetingRecord) -> MeetingRecord {
        let m = record.meeting
        return MeetingRecord(meeting: Meeting(
            id: m.id, projectID: m.projectID, title: m.title, titleIsAuto: m.titleIsAuto, startedAt: m.startedAt,
            durationSeconds: m.durationSeconds, status: m.status, source: m.source, importedFileName: m.importedFileName))
    }

    /// The base for a meeting made here, once the hub turns out to have it already and says where. A recording
    /// whose upload got there before its project did was filed in the Inbox; measuring against that makes the
    /// project it was made in a change this device still has to send, rather than one it takes from the hub.
    private static func asFiled(_ base: MeetingRecord, in projectID: UUID) -> MeetingRecord {
        var base = base
        base.meeting.projectID = projectID
        return base
    }

    // MARK: - Plumbing

    private func whileApplying(_ write: () -> Void) {
        applying = true
        defer { applying = false }
        write()
    }

    /// Run `work` after whatever is already running has finished.
    private func exclusively<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            return try await work()
        }
        queue = Task { _ = try? await task.value }
        return try await task.value
    }

    private func saveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.save()
        }
    }

    /// Write the ledger now. Call before the app is suspended.
    public func save() {
        saveTask?.cancel()
        saveTask = nil
        ledger.save(to: ledgerURL)
    }
}
