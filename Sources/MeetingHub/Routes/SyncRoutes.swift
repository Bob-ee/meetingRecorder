import Fluent
import Foundation
import MeetingCore
import Vapor

/// What devices use to stay in step: one request to hear what changed, one to say what they changed.
func syncRoutes(_ r: RoutesBuilder) {
    r.get("changes") { req -> ChangeSet in
        let p = try req.principal
        return try await ChangeFeed.changes(since: req.query[Int64.self, at: "since"] ?? 0,
                                            limit: req.query[Int.self, at: "limit"] ?? ChangeFeed.defaultPageSize,
                                            workspaceID: p.workspaceID, on: req.db)
    }

    r.post("meetings", ":id", "edits") { req -> MeetingRecord in
        let p = try req.principal
        let meeting = try await HubQueries.meeting(req, id: HubQueries.uuid(req, "id"))
        let edit = try req.content.decode(MeetingEdit.self)
        let oldProject = meeting.project
        // Looked up before the transaction opens, so that nothing inside it reads before it writes.
        var newProject: ProjectModel?
        if let id = edit.projectID, id != oldProject.id { newProject = try await HubQueries.project(req, id: id) }

        let destination = newProject
        try await req.db.transaction { tx in
            try await MeetingEdits.apply(edit, to: meeting, movingTo: destination, on: tx)
        }
        if newProject != nil {
            ExportMirror(root: req.application.hubPaths.export)
                .remove(meetingID: meeting.id!, workspace: p.workspace.name, projectName: oldProject.name)
        }
        let fresh = try await HubQueries.meeting(req, id: meeting.id!)
        HubQueries.broadcastMeeting(req, fresh)
        return try await ChangeFeed.record(fresh, on: req.db)
    }

    /// A pairing code for one more device, asked for from a device that is already trusted — which is how a
    /// phone gets paired from the Mac app instead of from a terminal on the hub.
    r.post("devices") { req -> PairDeviceResponse in
        let p = try req.principal
        let name = try req.content.decode(PairDeviceRequest.self).name.trimmingCharacters(in: .whitespaces)
        let code = try await Pairing.create(deviceName: name.isEmpty ? "Device" : name, user: p.user,
                                            workspace: p.workspace, app: req.application)
        return PairDeviceResponse(pairingCode: code)
    }
}

enum MeetingEdits {
    /// Apply one device's changes. `meeting` must have its action items loaded; nothing here reads from the
    /// database, so the transaction it runs in starts with a write (see `ChangeFeed.nextRevision`).
    ///
    /// Only what a person can change is taken from an item or an event. The rest — the advice written for an
    /// item, the quote it came from, an event's time — belongs to the hub, and a device working from an old
    /// copy must not be able to roll it back.
    static func apply(_ edit: MeetingEdit, to meeting: MeetingModel, movingTo project: ProjectModel?,
                      on db: any Database) async throws {
        let meetingID = try meeting.requireID()
        if let title = edit.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            meeting.title = title
            meeting.titleIsAuto = edit.titleIsAuto ?? false
        } else if let auto = edit.titleIsAuto {
            meeting.titleIsAuto = auto
        }
        if let notes = edit.notes { meeting.notes = notes }
        if let names = edit.speakerNames {
            var all = meeting.speakerNames
            for (speaker, name) in names { all[speaker] = name.isEmpty ? nil : name }
            meeting.speakerNames = all
        }
        if let project { meeting.$project.id = try project.requireID() }

        if !edit.changedEvents.isEmpty {
            var events = meeting.events
            for change in edit.changedEvents {
                guard let i = events.firstIndex(where: { $0.id == change.id }) else { continue }
                events[i].addedAt = change.addedAt
                events[i].dismissed = change.dismissed
            }
            meeting.events = events
        }

        var rows = Dictionary(uniqueKeysWithValues: meeting.actionItems.compactMap { row in row.id.map { ($0, row) } })
        for id in edit.removedItems {
            try await rows.removeValue(forKey: id)?.delete(on: db)
        }
        for item in edit.changedItems + edit.addedItems {
            guard !item.task.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let row = rows[item.id] {
                row.task = item.task
                row.owner = item.owner
                row.due = item.due
                row.dueDate = item.dueDate
                row.done = item.done
                row.calendarAddedAt = item.calendarAddedAt
                try await row.save(on: db)
            }
        }
        var position = (meeting.actionItems.map(\.position).max() ?? -1) + 1
        for item in edit.addedItems where rows[item.id] == nil
            && !item.task.trimmingCharacters(in: .whitespaces).isEmpty {
            let row = ActionItemModel(item, meetingID: meetingID, position: position)
            try await row.save(on: db)
            rows[item.id] = row
            position += 1
        }
        try await HubQueries.touch(meeting, on: db)
    }
}
