import Foundation
import MeetingCore
import MeetingSync

/// A meeting's transcript and summary as they are kept on the device.
struct MeetingContent: Codable {
    var transcript: [TranscriptSegment] = []
    var summary: String?
}

/// The device's copy of everything: projects, meetings, and whatever transcripts and summaries have been
/// fetched. It is a cache of the hub with this device's unsent edits on top — the sync engine reads it through
/// `SyncReplica` and writes the hub's changes back the same way.
///
/// Projects and meetings are small and live together in `library.json`. Transcripts are not, so each
/// meeting's content is its own file under `content/`, read only when something asks for it.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var projects: [ProjectDetail] = []
    @Published private(set) var meetings: [MeetingRecord] = []
    /// Counts transcripts and summaries arriving, so a view showing one knows to read it again.
    @Published private(set) var contentVersion = 0

    /// Fired after every edit made on this device, and never for what the hub sent.
    var onChange: ((LocalChange) -> Void)?

    private let file: URL
    private let contentDirectory: URL
    private var contentCache: [UUID: MeetingContent] = [:]
    private var searchCache: [UUID: String] = [:]
    private var saveTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var projects: [ProjectDetail]
        var meetings: [MeetingRecord]
    }

    init(directory: URL) {
        file = directory.appendingPathComponent("library.json")
        contentDirectory = directory.appendingPathComponent("content", isDirectory: true)
        try? FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file), let saved = try? jsonDecoder.decode(Snapshot.self, from: data) {
            projects = saved.projects
            meetings = saved.meetings
        }
    }

    // MARK: - Reading

    func project(_ id: UUID) -> ProjectDetail? { projects.first { $0.id == id } }
    func record(_ id: UUID) -> MeetingRecord? { meetings.first { $0.id == id } }
    func meeting(_ id: UUID) -> Meeting? { record(id)?.meeting }

    /// Newest first; nil means every project.
    func meetings(in projectID: UUID?) -> [Meeting] {
        meetings.map(\.meeting).filter { projectID == nil || $0.projectID == projectID }
    }

    /// Where a new recording goes when nothing more specific was chosen.
    var inbox: ProjectDetail? { projects.first { $0.project.name == "Inbox" } ?? projects.first }

    func content(for meetingID: UUID) -> MeetingContent {
        if let cached = contentCache[meetingID] { return cached }
        let content = (try? Data(contentsOf: contentFile(meetingID)))
            .flatMap { try? jsonDecoder.decode(MeetingContent.self, from: $0) } ?? MeetingContent()
        contentCache[meetingID] = content
        return content
    }

    func search(_ query: String, in projectID: UUID?) -> [Meeting] {
        let pool = meetings(in: projectID)
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return pool }
        return pool.filter { meeting in
            let text = searchableText(meeting.id)
            return terms.allSatisfy { text.contains($0) }
        }
    }

    private func searchableText(_ id: UUID) -> String {
        if let cached = searchCache[id] { return cached }
        guard let record = record(id) else { return "" }
        let content = content(for: id)
        var parts = [record.meeting.title, record.notes]
        parts += record.meeting.actionItems.map(\.task)
        parts += record.meeting.events.map(\.title)
        if let summary = content.summary { parts.append(summary) }
        parts += content.transcript.map(\.text)
        let text = parts.joined(separator: "\n").lowercased()
        searchCache[id] = text
        return text
    }

    // MARK: - Editing meetings

    /// Change a meeting and tell the sync engine. Every edit the UI makes comes through here.
    func edit(meeting id: UUID, _ change: (inout MeetingRecord) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        var record = meetings[i]
        change(&record)
        guard record != meetings[i] else { return }
        meetings[i] = record
        searchCache[id] = nil
        saveSoon()
        onChange?(.meeting(id))
    }

    func rename(meeting id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        edit(meeting: id) { record in
            guard record.meeting.title != title else { return }
            record.meeting.title = title
            record.meeting.titleIsAuto = false
        }
    }

    func setNotes(_ notes: String, for id: UUID) {
        edit(meeting: id) { $0.notes = notes }
    }

    /// An empty name, or the speaker's own label, puts the default label back.
    func renameSpeaker(_ speaker: String, to name: String, in id: UUID) {
        let name = name.trimmingCharacters(in: .whitespaces)
        edit(meeting: id) { $0.meeting.speakerNames[speaker] = name.isEmpty || name == speaker ? nil : name }
    }

    func move(meeting id: UUID, to projectID: UUID) {
        guard project(projectID) != nil else { return }
        edit(meeting: id) { $0.meeting.projectID = projectID }
    }

    func addItem(_ task: String, to id: UUID) {
        let task = task.trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty else { return }
        edit(meeting: id) { $0.meeting.actionItems.append(ActionItem(task: task, isManual: true)) }
    }

    func update(_ item: ActionItem, in id: UUID) {
        edit(meeting: id) { record in
            guard let i = record.meeting.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
            record.meeting.actionItems[i] = item
        }
    }

    func removeItem(_ itemID: UUID, from id: UUID) {
        edit(meeting: id) { $0.meeting.actionItems.removeAll { $0.id == itemID } }
    }

    func update(_ event: MeetingEvent, in id: UUID) {
        edit(meeting: id) { record in
            guard let i = record.meeting.events.firstIndex(where: { $0.id == event.id }) else { return }
            record.meeting.events[i] = event
        }
    }

    func restoreHiddenEvents(in id: UUID) {
        edit(meeting: id) { record in
            for i in record.meeting.events.indices { record.meeting.events[i].dismissed = false }
        }
    }

    /// A meeting recorded on, or shared into, this device.
    @discardableResult
    func createMeeting(id: UUID, in projectID: UUID, title: String, source: MeetingSource, startedAt: Date,
                       duration: Double, importedFileName: String? = nil) -> Meeting {
        let meeting = Meeting(id: id, projectID: projectID, title: title, titleIsAuto: true, startedAt: startedAt,
                              durationSeconds: duration, status: .recorded, source: source,
                              importedFileName: importedFileName)
        insert(MeetingRecord(meeting: meeting))
        saveSoon()
        onChange?(.newMeeting(id))
        return meeting
    }

    func deleteMeeting(_ id: UUID) {
        guard record(id) != nil else { return }
        remove(meeting: id)
        saveSoon()
        onChange?(.removedMeeting(id))
    }

    // MARK: - Editing projects

    @discardableResult
    func createProject(name: String) -> ProjectDetail? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let project = ProjectDetail(project: Project(name: name), context: "", meetingCount: 0)
        insert(project)
        saveSoon()
        onChange?(.project(project.id))
        return project
    }

    func edit(project id: UUID, _ change: (inout ProjectDetail) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        var project = projects[i]
        change(&project)
        guard !SyncMerge.same(project, projects[i]) else { return }
        insert(project)
        saveSoon()
        onChange?(.project(id))
    }

    /// The project goes, and its meetings with it.
    func deleteProject(_ id: UUID) {
        guard project(id) != nil else { return }
        remove(project: id)
        saveSoon()
        onChange?(.removedProject(id))
    }

    // MARK: - Storage

    private func insert(_ project: ProjectDetail) {
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        projects.sort { $0.project.name.localizedCaseInsensitiveCompare($1.project.name) == .orderedAscending }
    }

    private func insert(_ record: MeetingRecord) {
        meetings.removeAll { $0.id == record.id }
        meetings.append(record)
        meetings.sort { $0.meeting.startedAt > $1.meeting.startedAt }
        searchCache[record.id] = nil
    }

    private func remove(meeting id: UUID) {
        meetings.removeAll { $0.id == id }
        contentCache[id] = nil
        searchCache[id] = nil
        try? FileManager.default.removeItem(at: contentFile(id))
    }

    private func remove(project id: UUID) {
        for meeting in meetings(in: id) { remove(meeting: meeting.id) }
        projects.removeAll { $0.id == id }
    }

    private func contentFile(_ id: UUID) -> URL {
        contentDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Edits come in bursts (typing in the notes field); one write a moment later covers them all.
    private func saveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.flush()
        }
    }

    /// Write to disk now. Called before the app is suspended.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try wireEncoder.encode(Snapshot(projects: projects, meetings: meetings)).write(to: file, options: .atomic)
        } catch {
            Log.hub.error("couldn't save the library: \(error.localizedDescription)")
        }
    }

    /// Forget everything — the device is being unpaired from its hub.
    func wipe() {
        projects = []
        meetings = []
        contentCache = [:]
        searchCache = [:]
        try? FileManager.default.removeItem(at: contentDirectory)
        try? FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        flush()
    }
}

// MARK: - What the sync engine sees

extension Library: SyncReplica {
    func projectRecord(_ id: UUID) -> ProjectDetail? { project(id) }
    func meetingRecord(_ id: UUID) -> MeetingRecord? { record(id) }

    func apply(_ project: ProjectDetail) {
        insert(project)
        saveSoon()
    }

    func apply(_ meeting: MeetingRecord) {
        insert(meeting)
        saveSoon()
    }

    func applyContent(transcript: [TranscriptSegment], summary: String?, for meetingID: UUID) {
        let content = MeetingContent(transcript: transcript, summary: summary)
        contentCache[meetingID] = content
        searchCache[meetingID] = nil
        do {
            try wireEncoder.encode(content).write(to: contentFile(meetingID), options: .atomic)
        } catch {
            Log.hub.error("couldn't cache a transcript: \(error.localizedDescription)")
        }
        contentVersion += 1
    }

    func discardProject(_ id: UUID) {
        remove(project: id)
        saveSoon()
    }

    func discardMeeting(_ id: UUID) {
        remove(meeting: id)
        saveSoon()
    }
}
