import Foundation
import MeetingCore
import MeetingSync

/// The Mac's folder of meetings, as the sync engine sees it.
@MainActor
final class StoreReplica: SyncReplica {
    private let store: Store
    /// Meetings whose audio this Mac is still getting to the hub. Until that's done their status is this Mac's
    /// to say — the hub would call them "recorded", which reads as if nothing were happening.
    var uploading: Set<UUID> = []

    init(store: Store) { self.store = store }

    func projectRecord(_ id: UUID) -> ProjectDetail? {
        store.project(id).map {
            ProjectDetail(project: $0, context: store.projectContext(id), learnedContext: store.learnedContext(id), meetingCount: 0)
        }
    }

    func meetingRecord(_ id: UUID) -> MeetingRecord? {
        store.meeting(id).map { MeetingRecord(meeting: $0, notes: store.notes(for: $0)) }
    }

    func apply(_ project: ProjectDetail) {
        let id = project.id
        if let local = store.project(id) {
            if local.name != project.project.name { store.renameProject(id, to: project.project.name) }
        } else {
            store.createProject(id: id, name: project.project.name)
        }
        if store.projectContext(id) != project.context { store.setProjectContext(id, project.context) }
        if store.learnedContext(id) != project.learnedContext {
            store.setLearnedContext(id, project.learnedContext, note: "Updated on the hub.")
        }
    }

    func apply(_ record: MeetingRecord) {
        var meeting = record.meeting
        // The feed lists a project before the meetings in it, so a missing one means its folder is gone from
        // this Mac. Filing the meeting somewhere else would look like a move, and be synced back as one.
        guard store.project(meeting.projectID) != nil else { return }
        if let local = store.meeting(meeting.id) {
            if uploading.contains(meeting.id) {
                meeting.status = local.status
                meeting.errorMessage = local.errorMessage
            }
            if local.projectID != meeting.projectID { store.moveMeeting(meeting.id, to: meeting.projectID) }
        } else {
            _ = store.createMeeting(id: meeting.id, in: meeting.projectID, title: meeting.title,
                                    source: meeting.source, startedAt: meeting.startedAt)
        }
        store.update(meeting)
        if store.notes(for: meeting) != record.notes { store.saveNotes(record.notes, for: meeting) }
    }

    func applyContent(transcript: [TranscriptSegment], summary: String?, for meetingID: UUID) {
        guard let meeting = store.meeting(meetingID) else { return }
        if !transcript.isEmpty { store.saveTranscript(transcript, for: meeting) }
        if let summary { store.saveSummary(summary, for: meeting) }
    }

    func discardProject(_ id: UUID) { store.deleteProject(id) }
    func discardMeeting(_ id: UUID) { store.deleteMeeting(id) }
}
