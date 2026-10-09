import Foundation
import MeetingCore

/// What a device remembers about its last conversation with the hub: how far through the change feed it has
/// read, the hub's copy of everything as of then, and what it still owes the hub.
struct SyncLedger: Codable {
    /// The workspace all of this refers to. Pairing with a different one starts a new ledger.
    var workspaceID: UUID?
    /// The feed has been read up to here.
    var cursor: Int64 = 0

    /// The hub's copy of each project and meeting, as last seen — the base that local edits are measured from.
    /// For something made on this device and not yet sent, it is the copy as it was made.
    var projects: [UUID: ProjectDetail] = [:]
    var meetings: [UUID: MeetingRecord] = [:]
    /// The transcript and summary held locally for each meeting, by the tag they were fetched under.
    var contentTags: [UUID: String] = [:]

    /// Made here; the hub hasn't been told yet.
    var unsentProjects: Set<UUID> = []
    var unsentMeetings: Set<UUID> = []
    /// Edited here since the base; may need sending.
    var dirtyProjects: Set<UUID> = []
    var dirtyMeetings: Set<UUID> = []
    /// Deleted here; the hub hasn't been told yet.
    var removedProjects: Set<UUID> = []
    var removedMeetings: Set<UUID> = []

    var hasUnsentWork: Bool {
        !(dirtyProjects.isEmpty && dirtyMeetings.isEmpty && removedProjects.isEmpty && removedMeetings.isEmpty)
    }

    mutating func forget(meeting id: UUID) {
        meetings[id] = nil; contentTags[id] = nil
        unsentMeetings.remove(id); dirtyMeetings.remove(id)
    }

    mutating func forget(project id: UUID) {
        projects[id] = nil
        unsentProjects.remove(id); dirtyProjects.remove(id)
    }

    static func load(from url: URL) -> SyncLedger {
        guard let data = try? Data(contentsOf: url), let ledger = try? jsonDecoder.decode(SyncLedger.self, from: data) else {
            return SyncLedger()
        }
        return ledger
    }

    func save(to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wireEncoder.encode(self).write(to: url, options: .atomic)
        } catch {
            Log.hub.error("couldn't save the sync ledger: \(error.localizedDescription)")
        }
    }
}
