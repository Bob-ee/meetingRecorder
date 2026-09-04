import Fluent
import Foundation
import MeetingCore

// Every row that belongs to someone is scoped by workspace, so multi-user is a matter of adding rows, not columns.

final class UserModel: Model, @unchecked Sendable {
    static let schema = "users"
    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @OptionalField(key: "email") var email: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(name: String, email: String? = nil) { self.name = name; self.email = email }

    var dto: HubUser { HubUser(id: id ?? UUID(), name: name, email: email) }
}

final class WorkspaceModel: Model, @unchecked Sendable {
    static let schema = "workspaces"
    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Parent(key: "owner_id") var owner: UserModel
    @Field(key: "plan") var plan: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(name: String, ownerID: UUID, plan: String = "self-hosted") { self.name = name; self.$owner.id = ownerID; self.plan = plan }

    var dto: HubWorkspace { HubWorkspace(id: id ?? UUID(), name: name) }
}

final class WorkspaceMemberModel: Model, @unchecked Sendable {
    static let schema = "workspace_members"
    @ID(key: .id) var id: UUID?
    @Parent(key: "workspace_id") var workspace: WorkspaceModel
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "role") var role: String
    init() {}
    init(workspaceID: UUID, userID: UUID, role: String) { self.$workspace.id = workspaceID; self.$user.id = userID; self.role = role }
}

final class DeviceTokenModel: Model, @unchecked Sendable {
    static let schema = "device_tokens"
    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Parent(key: "workspace_id") var workspace: WorkspaceModel
    @Field(key: "name") var name: String
    @Field(key: "token_hash") var tokenHash: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    init() {}
    init(userID: UUID, workspaceID: UUID, name: String, tokenHash: String) {
        self.$user.id = userID; self.$workspace.id = workspaceID; self.name = name; self.tokenHash = tokenHash
    }
}

final class ProjectModel: Model, @unchecked Sendable {
    static let schema = "projects"
    @ID(key: .id) var id: UUID?
    @Parent(key: "workspace_id") var workspace: WorkspaceModel
    @Field(key: "name") var name: String
    @Field(key: "context") var context: String
    /// What the summarizer has worked out about this project by itself. Null until it writes one.
    @OptionalField(key: "learned_context") var learnedContextRaw: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Children(for: \.$project) var meetings: [MeetingModel]
    init() {}
    init(id: UUID? = nil, workspaceID: UUID, name: String, context: String = "") {
        self.id = id; self.$workspace.id = workspaceID; self.name = name; self.context = context
    }

    var learnedContext: String {
        get { learnedContextRaw ?? "" }
        set { learnedContextRaw = newValue.isEmpty ? nil : newValue }
    }

    var dto: Project { Project(id: id ?? UUID(), name: name, createdAt: createdAt ?? Date(), updatedAt: updatedAt ?? createdAt) }
}

final class MeetingModel: Model, @unchecked Sendable {
    static let schema = "meetings"
    @ID(key: .id) var id: UUID?
    @Parent(key: "workspace_id") var workspace: WorkspaceModel
    @Parent(key: "project_id") var project: ProjectModel
    @Field(key: "title") var title: String
    @Field(key: "title_is_auto") var titleIsAuto: Bool
    @Field(key: "started_at") var startedAt: Date
    @Field(key: "duration_seconds") var durationSeconds: Double
    @Field(key: "status") var status: String
    @Field(key: "source") var source: String
    @OptionalField(key: "imported_file_name") var importedFileName: String?
    @OptionalField(key: "error_message") var errorMessage: String?
    @Field(key: "speaker_names") var speakerNamesJSON: String
    @Field(key: "notes") var notes: String
    /// Suggested calendar events, as JSON (nil on rows from before they existed).
    @OptionalField(key: "events") var eventsJSON: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Children(for: \.$meeting) var actionItems: [ActionItemModel]
    init() {}

    var speakerNames: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(speakerNamesJSON.utf8))) ?? [:] }
        set { speakerNamesJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("{}".utf8), as: UTF8.self) }
    }

    var events: [MeetingEvent] {
        get { eventsJSON.flatMap { try? jsonDecoder.decode([MeetingEvent].self, from: Data($0.utf8)) } ?? [] }
        set { eventsJSON = newValue.isEmpty ? nil : String(decoding: (try? wireEncoder.encode(newValue)) ?? Data("[]".utf8), as: UTF8.self) }
    }

    var meetingStatus: MeetingStatus {
        get { MeetingStatus(rawValue: status) ?? .recorded }
        set { status = newValue.rawValue }
    }

    /// Requires `actionItems` to be loaded.
    func dto(actionItems items: [ActionItemModel]? = nil) -> Meeting {
        let loaded = items ?? $actionItems.value ?? []
        return Meeting(id: id ?? UUID(), projectID: $project.id, title: title, titleIsAuto: titleIsAuto, startedAt: startedAt,
                       durationSeconds: durationSeconds, status: meetingStatus, source: MeetingSource(rawValue: source) ?? .live,
                       actionItems: loaded.sorted { $0.position < $1.position }.map(\.dto), events: events,
                       speakerNames: speakerNames, errorMessage: errorMessage, importedFileName: importedFileName,
                       updatedAt: updatedAt ?? createdAt ?? startedAt)
    }
}

final class ActionItemModel: Model, @unchecked Sendable {
    static let schema = "action_items"
    @ID(key: .id) var id: UUID?
    @Parent(key: "meeting_id") var meeting: MeetingModel
    @Field(key: "task") var task: String
    @OptionalField(key: "owner") var owner: String?
    @OptionalField(key: "due") var due: String?
    /// `EventDate` as JSON.
    @OptionalField(key: "due_date") var dueDateJSON: String?
    @Field(key: "done") var done: Bool
    @Field(key: "is_manual") var isManual: Bool
    @Field(key: "position") var position: Int
    @OptionalField(key: "calendar_added_at") var calendarAddedAt: Date?
    @OptionalField(key: "source_quote") var sourceQuote: String?
    @OptionalField(key: "guidance") var guidance: String?
    @OptionalField(key: "guidance_at") var guidanceAt: Date?
    @OptionalField(key: "last_discussed_meeting_id") var lastDiscussedMeetingID: UUID?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(_ item: ActionItem, meetingID: UUID, position: Int) {
        id = item.id; $meeting.id = meetingID; task = item.task; owner = item.owner; due = item.due
        dueDate = item.dueDate; done = item.done; isManual = item.isManual; self.position = position
        calendarAddedAt = item.calendarAddedAt; sourceQuote = item.sourceQuote; guidance = item.guidance
        guidanceAt = item.guidanceAt; lastDiscussedMeetingID = item.lastDiscussedMeetingID
    }

    var dueDate: EventDate? {
        get { dueDateJSON.flatMap { try? jsonDecoder.decode(EventDate.self, from: Data($0.utf8)) } }
        set { dueDateJSON = newValue.flatMap { try? wireEncoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } }
    }

    var dto: ActionItem {
        ActionItem(id: id ?? UUID(), task: task, owner: owner, due: due, dueDate: dueDate, done: done, isManual: isManual,
                   calendarAddedAt: calendarAddedAt, sourceQuote: sourceQuote, guidance: guidance,
                   guidanceAt: guidanceAt, lastDiscussedMeetingID: lastDiscussedMeetingID)
    }
}

final class TranscriptModel: Model, @unchecked Sendable {
    static let schema = "transcripts"
    @ID(key: .id) var id: UUID?
    @Parent(key: "meeting_id") var meeting: MeetingModel
    @Field(key: "segments") var segmentsJSON: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(meetingID: UUID, segments: [TranscriptSegment]) {
        $meeting.id = meetingID
        segmentsJSON = String(decoding: (try? wireEncoder.encode(segments)) ?? Data("[]".utf8), as: UTF8.self)
    }
    var segments: [TranscriptSegment] { (try? jsonDecoder.decode([TranscriptSegment].self, from: Data(segmentsJSON.utf8))) ?? [] }
}

final class SummaryModel: Model, @unchecked Sendable {
    static let schema = "summaries"
    @ID(key: .id) var id: UUID?
    @Parent(key: "meeting_id") var meeting: MeetingModel
    @Field(key: "json") var json: String
    @Field(key: "markdown") var markdown: String
    @Field(key: "provider") var provider: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(meetingID: UUID, summary: MeetingSummary, markdown: String, provider: String) {
        $meeting.id = meetingID
        json = String(decoding: (try? wireEncoder.encode(summary)) ?? Data("{}".utf8), as: UTF8.self)
        self.markdown = markdown; self.provider = provider
    }
}

final class AudioFileModel: Model, @unchecked Sendable {
    static let schema = "audio_files"
    @ID(key: .id) var id: UUID?
    @Parent(key: "meeting_id") var meeting: MeetingModel
    @Field(key: "kind") var kind: String
    @Field(key: "file_name") var fileName: String
    @Field(key: "byte_size") var byteSize: Int
    @OptionalField(key: "sha256") var sha256: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(meetingID: UUID, kind: AudioTrackKind, fileName: String, byteSize: Int, sha256: String?) {
        $meeting.id = meetingID; self.kind = kind.rawValue; self.fileName = fileName; self.byteSize = byteSize; self.sha256 = sha256
    }
    var dto: AudioTrackInfo { AudioTrackInfo(kind: AudioTrackKind(rawValue: kind) ?? .imported, fileName: fileName, byteSize: byteSize, sha256: sha256) }
}

final class JobModel: Model, @unchecked Sendable {
    static let schema = "jobs"
    @ID(key: .id) var id: UUID?
    @Parent(key: "workspace_id") var workspace: WorkspaceModel
    @Parent(key: "meeting_id") var meeting: MeetingModel
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "steps") var stepsRaw: String
    @Field(key: "status") var status: String
    @OptionalField(key: "progress") var progress: String?
    @OptionalField(key: "error") var error: String?
    @Field(key: "attempts") var attempts: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "started_at") var startedAt: Date?
    @OptionalField(key: "finished_at") var finishedAt: Date?
    init() {}
    init(workspaceID: UUID, meetingID: UUID, userID: UUID, steps: [JobStep]) {
        $workspace.id = workspaceID; $meeting.id = meetingID; $user.id = userID
        stepsRaw = steps.map(\.rawValue).joined(separator: ","); status = JobStatus.queued.rawValue; attempts = 0
    }
    var steps: [JobStep] { stepsRaw.split(separator: ",").compactMap { JobStep(rawValue: String($0)) } }
    var jobStatus: JobStatus {
        get { JobStatus(rawValue: status) ?? .queued }
        set { status = newValue.rawValue }
    }
    var dto: JobInfo {
        JobInfo(id: id ?? UUID(), meetingID: $meeting.id, steps: steps, status: jobStatus, progress: progress, error: error,
                createdAt: createdAt ?? Date(), startedAt: startedAt, finishedAt: finishedAt)
    }
}

final class SettingModel: Model, @unchecked Sendable {
    static let schema = "settings"
    @ID(key: .id) var id: UUID?
    @Parent(key: "workspace_id") var workspace: WorkspaceModel
    @Field(key: "key") var key: String
    @Field(key: "value") var value: String
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(workspaceID: UUID, key: String, value: String) { $workspace.id = workspaceID; self.key = key; self.value = value }
}
