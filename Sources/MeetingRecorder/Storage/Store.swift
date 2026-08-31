import Foundation
import MeetingCore
import AppKit

/// Everything lives as plain files under `rootURL`:
///
///     <root>/<Project>/project.json
///     <root>/<Project>/CONTEXT.md
///     <root>/<Project>/<yyyy-MM-dd HHmm Title>/meeting.json
///                                             /mic.caf, system.caf (or import.<ext>)
///                                             /transcript.json, transcript.md
///                                             /summary.md, notes.md
@MainActor
final class Store: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var rootURL: URL

    private var projectFolders: [UUID: URL] = [:]
    private var meetingFolders: [UUID: URL] = [:]
    private var textCache: [UUID: String] = [:]
    private let fm = FileManager.default

    static let inboxName = "Inbox"

    /// Fired after every local mutation so hub sync can push it. Not fired for what the hub itself sent us.
    var onChange: ((StoreChange) -> Void)?

    init(rootURL: URL) {
        self.rootURL = rootURL
        reload()
    }

    // MARK: - Loading

    func setRoot(_ url: URL) {
        rootURL = url
        reload()
    }

    func reload() {
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var loadedProjects: [Project] = []
        var loadedMeetings: [Meeting] = []
        projectFolders = [:]; meetingFolders = [:]; textCache = [:]

        let projectDirs = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in projectDirs where dir.hasDirectoryPath {
            let pj = dir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: pj), let project = try? jsonDecoder.decode(Project.self, from: data) else { continue }
            loadedProjects.append(project)
            projectFolders[project.id] = dir

            let meetingDirs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for mdir in meetingDirs where mdir.hasDirectoryPath {
                let mj = mdir.appendingPathComponent("meeting.json")
                guard let mdata = try? Data(contentsOf: mj), var meeting = try? jsonDecoder.decode(Meeting.self, from: mdata) else { continue }
                meeting.projectID = project.id
                loadedMeetings.append(meeting)
                meetingFolders[meeting.id] = mdir
            }
        }
        projects = loadedProjects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        meetings = loadedMeetings.sorted { $0.startedAt > $1.startedAt }
        if projects.isEmpty { createProject(name: Store.inboxName) }
        adoptNewProjectFolders()
    }

    /// A folder someone made in Finder under the root becomes a project (so "new folder = new project" just works).
    /// Also picks up project folders that appeared since the last scan.
    func adoptNewProjectFolders() {
        let dirs = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in dirs where dir.hasDirectoryPath && !dir.lastPathComponent.hasPrefix("_") {
            if projectFolders.values.contains(where: { $0.standardizedFileURL == dir.standardizedFileURL }) { continue }
            let pj = dir.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: pj), let project = try? jsonDecoder.decode(Project.self, from: data) {
                if projects.contains(where: { $0.id == project.id }) { continue }
                projects.append(project)
                projectFolders[project.id] = dir
            } else {
                let project = Project(name: dir.lastPathComponent)
                writeJSON(project, to: pj)
                projects.append(project)
                projectFolders[project.id] = dir
            }
        }
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Forget meetings/projects whose folders were deleted or moved away in Finder.
    func pruneMissing() {
        let goneMeetings = meetings.filter { m in
            guard let dir = meetingFolders[m.id] else { return true }
            return !fm.fileExists(atPath: dir.appendingPathComponent("meeting.json").path)
        }
        for m in goneMeetings {
            let projectStillThere = projectFolders[m.projectID].map { fm.fileExists(atPath: $0.path) } ?? false
            meetingFolders[m.id] = nil
            textCache[m.id] = nil
            // A meeting folder removed in Finder while its project is still here is a deliberate delete —
            // tell the hub. A vanished project folder (unmounted drive, iCloud eviction) is not.
            if projectStillThere { onChange?(.deletedMeeting(m.id)) }
        }
        if !goneMeetings.isEmpty { meetings.removeAll { m in goneMeetings.contains { $0.id == m.id } } }
        let goneProjects = projects.filter { p in
            guard let dir = projectFolders[p.id] else { return true }
            return !fm.fileExists(atPath: dir.path)
        }
        for p in goneProjects {
            projectFolders[p.id] = nil
            meetings.removeAll { $0.projectID == p.id }
        }
        if !goneProjects.isEmpty { projects.removeAll { p in goneProjects.contains { $0.id == p.id } } }
        if projects.isEmpty { createProject(name: Store.inboxName) }
    }

    func folder(forProject id: UUID) -> URL? { projectFolders[id] }
    var projectFolderURLs: [URL] { Array(projectFolders.values) }

    /// Audio files sitting directly in the root or in a project folder (dropped there via Finder/AirDrop),
    /// paired with the project they belong to. Meeting subfolders are never scanned.
    func looseAudioFiles() -> [(projectID: UUID, url: URL)] {
        var found: [(UUID, URL)] = []
        func scan(_ dir: URL, projectID: UUID) {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            for item in items where AudioImporter.isAudioFile(item) { found.append((projectID, item)) }
        }
        scan(rootURL, projectID: inboxProject.id)
        for (id, dir) in projectFolders { scan(dir, projectID: id) }
        return found.map { (projectID: $0.0, url: $0.1) }
    }

    // MARK: - Projects

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    var inboxProject: Project {
        if let p = projects.first(where: { $0.name == Store.inboxName }) { return p }
        if let p = projects.first { return p }
        return createProject(name: Store.inboxName)
    }

    @discardableResult
    func createProject(id: UUID? = nil, name: String) -> Project {
        let project = Project(id: id ?? UUID(), name: name)
        let dir = uniqueURL(in: rootURL, base: Fmt.sanitizeFilename(name))
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        projectFolders[project.id] = dir
        writeJSON(project, to: dir.appendingPathComponent("project.json"))
        projects.append(project)
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onChange?(.project(project))
        return project
    }

    func renameProject(_ id: UUID, to name: String) {
        guard var p = project(id), let dir = projectFolders[id] else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        p.name = trimmed
        let target = rootURL.appendingPathComponent(Fmt.sanitizeFilename(trimmed), isDirectory: true)
        if target.lastPathComponent != dir.lastPathComponent, !fm.fileExists(atPath: target.path) {
            if (try? fm.moveItem(at: dir, to: target)) != nil {
                projectFolders[id] = target
                for m in meetings where m.projectID == id {
                    if let old = meetingFolders[m.id] {
                        meetingFolders[m.id] = target.appendingPathComponent(old.lastPathComponent, isDirectory: true)
                    }
                }
            }
        }
        writeJSON(p, to: projectFolders[id]!.appendingPathComponent("project.json"))
        if let i = projects.firstIndex(where: { $0.id == id }) { projects[i] = p }
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onChange?(.project(p))
    }

    func deleteProject(_ id: UUID) {
        guard let dir = projectFolders[id] else { return }
        try? fm.trashItem(at: dir, resultingItemURL: nil)
        projects.removeAll { $0.id == id }
        for m in meetings where m.projectID == id { meetingFolders[m.id] = nil; textCache[m.id] = nil }
        meetings.removeAll { $0.projectID == id }
        projectFolders[id] = nil
        onChange?(.deletedProject(id))
        if projects.isEmpty { createProject(name: Store.inboxName) }
    }

    /// Give a local project the id the hub uses for it (same name, different id). Folder and meetings stay put.
    func adoptProjectID(_ oldID: UUID, newID: UUID) {
        guard oldID != newID, var p = project(oldID), let dir = projectFolders[oldID], project(newID) == nil else { return }
        p.id = newID
        writeJSON(p, to: dir.appendingPathComponent("project.json"))
        projectFolders[newID] = dir
        projectFolders[oldID] = nil
        if let i = projects.firstIndex(where: { $0.id == oldID }) { projects[i] = p }
        for i in meetings.indices where meetings[i].projectID == oldID {
            meetings[i].projectID = newID
            if let mdir = meetingFolders[meetings[i].id] { writeJSON(meetings[i], to: mdir.appendingPathComponent("meeting.json")) }
        }
    }

    func projectContext(_ id: UUID) -> String {
        guard let dir = projectFolders[id] else { return "" }
        return (try? String(contentsOf: dir.appendingPathComponent("CONTEXT.md"), encoding: .utf8)) ?? ""
    }

    func setProjectContext(_ id: UUID, _ text: String) {
        guard let dir = projectFolders[id] else { return }
        try? text.write(to: dir.appendingPathComponent("CONTEXT.md"), atomically: true, encoding: .utf8)
        if let p = project(id) { onChange?(.project(p)) }
    }

    // MARK: - Meetings

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func meetings(in projectID: UUID?) -> [Meeting] {
        guard let projectID else { return meetings }
        return meetings.filter { $0.projectID == projectID }
    }

    func folder(for meeting: Meeting) -> URL {
        meetingFolders[meeting.id] ?? rootURL.appendingPathComponent("_orphaned/\(meeting.id.uuidString)", isDirectory: true)
    }

    func createMeeting(id: UUID? = nil, in projectID: UUID, title: String, source: MeetingSource, startedAt: Date = Date()) -> Meeting {
        let pid = project(projectID)?.id ?? inboxProject.id
        let meeting = Meeting(id: id ?? UUID(), projectID: pid, title: title, titleIsAuto: true, startedAt: startedAt, source: source)
        let pdir = projectFolders[pid]!
        let dir = uniqueURL(in: pdir, base: "\(Fmt.folderStamp.string(from: startedAt)) \(Fmt.sanitizeFilename(title))")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        meetingFolders[meeting.id] = dir
        writeJSON(meeting, to: dir.appendingPathComponent("meeting.json"))
        meetings.insert(meeting, at: 0)
        meetings.sort { $0.startedAt > $1.startedAt }
        return meeting
    }

    func update(_ input: Meeting) {
        var meeting = input
        meeting.updatedAt = Date()
        guard let dir = meetingFolders[meeting.id] else { return }
        // Keep folder name in sync with the title when it is safe to do so.
        let desired = "\(Fmt.folderStamp.string(from: meeting.startedAt)) \(Fmt.sanitizeFilename(meeting.title))"
        if dir.lastPathComponent != desired {
            let target = dir.deletingLastPathComponent().appendingPathComponent(desired, isDirectory: true)
            if !fm.fileExists(atPath: target.path), (try? fm.moveItem(at: dir, to: target)) != nil {
                meetingFolders[meeting.id] = target
            }
        }
        writeJSON(meeting, to: folder(for: meeting).appendingPathComponent("meeting.json"))
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[i] = meeting } else { meetings.append(meeting) }
        meetings.sort { $0.startedAt > $1.startedAt }
        textCache[meeting.id] = nil
        onChange?(.meeting(meeting))
    }

    func deleteMeeting(_ id: UUID) {
        if let dir = meetingFolders[id] { try? fm.trashItem(at: dir, resultingItemURL: nil) }
        meetingFolders[id] = nil
        textCache[id] = nil
        meetings.removeAll { $0.id == id }
        onChange?(.deletedMeeting(id))
    }

    func moveMeeting(_ id: UUID, to projectID: UUID) {
        guard var m = meeting(id), let dir = meetingFolders[id], let pdir = projectFolders[projectID], m.projectID != projectID else { return }
        let target = uniqueURL(in: pdir, base: dir.lastPathComponent)
        guard (try? fm.moveItem(at: dir, to: target)) != nil else { return }
        meetingFolders[id] = target
        m.projectID = projectID
        update(m)
    }

    // MARK: - Files

    /// Raw capture targets (CAF). After transcription these are compressed to .m4a — use `existingTrackURL` to read.
    func micURL(for meeting: Meeting) -> URL { folder(for: meeting).appendingPathComponent("mic.caf") }
    func systemURL(for meeting: Meeting) -> URL { folder(for: meeting).appendingPathComponent("system.caf") }

    func existingTrackURL(_ track: String, for meeting: Meeting) -> URL? {
        let dir = folder(for: meeting)
        for ext in ["caf", "m4a"] {
            let url = dir.appendingPathComponent("\(track).\(ext)")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
    func importedURL(for meeting: Meeting) -> URL? {
        guard let name = meeting.importedFileName else { return nil }
        return folder(for: meeting).appendingPathComponent(name)
    }
    func exists(_ url: URL?) -> Bool { url.map { fm.fileExists(atPath: $0.path) } ?? false }

    /// Audio to treat as "everyone else" when transcribing.
    func remoteAudioURL(for meeting: Meeting) -> URL? {
        if let u = importedURL(for: meeting), exists(u) { return u }
        return existingTrackURL("system", for: meeting)
    }

    func transcript(for meeting: Meeting) -> [TranscriptSegment] {
        let url = folder(for: meeting).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? jsonDecoder.decode([TranscriptSegment].self, from: data)) ?? []
    }

    func hasTranscript(_ meeting: Meeting) -> Bool {
        fm.fileExists(atPath: folder(for: meeting).appendingPathComponent("transcript.json").path)
    }

    func saveTranscript(_ segments: [TranscriptSegment], for meeting: Meeting) {
        let dir = folder(for: meeting)
        writeJSON(segments, to: dir.appendingPathComponent("transcript.json"))
        let md = transcriptMarkdown(segments, meeting: meeting)
        try? md.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        textCache[meeting.id] = nil
    }

    func transcriptMarkdown(_ segments: [TranscriptSegment], meeting: Meeting) -> String {
        MeetingDocuments.transcriptMarkdown(segments, meeting: meeting)
    }

    func renameSpeaker(_ speaker: String, to name: String, in meetingID: UUID) {
        guard var m = meeting(meetingID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == speaker { m.speakerNames[speaker] = nil } else { m.speakerNames[speaker] = trimmed }
        update(m)
        let segs = transcript(for: m)
        if !segs.isEmpty {
            let md = transcriptMarkdown(segs, meeting: m)
            try? md.write(to: folder(for: m).appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        }
    }

    func summaryMarkdown(for meeting: Meeting) -> String? {
        try? String(contentsOf: folder(for: meeting).appendingPathComponent("summary.md"), encoding: .utf8)
    }

    /// Action items as a Markdown checklist, checked state included.
    func actionItemsMarkdown(_ meeting: Meeting) -> String {
        MeetingDocuments.actionItemsMarkdown(meeting.actionItems)
    }

    /// summary.md with its "Action items" section swapped for the live list (done states, manual additions).
    func summaryExport(for meeting: Meeting) -> String? {
        guard let md = summaryMarkdown(for: meeting) else { return nil }
        return MeetingDocuments.summaryExport(summaryMarkdown: md, actionItems: meeting.actionItems, events: meeting.events)
    }

    func saveSummary(_ markdown: String, for meeting: Meeting) {
        try? markdown.write(to: folder(for: meeting).appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        textCache[meeting.id] = nil
    }

    func notes(for meeting: Meeting) -> String {
        (try? String(contentsOf: folder(for: meeting).appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
    }

    func saveNotes(_ text: String, for meeting: Meeting) {
        try? text.write(to: folder(for: meeting).appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        textCache[meeting.id] = nil
        onChange?(.notes(meeting))
    }

    func revealInFinder(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([folder(for: meeting)])
    }

    /// One Markdown blob with everything, for pasting into Claude.
    func exportForClaude(_ meeting: Meeting) -> String {
        MeetingDocuments.everything(meeting: meeting, projectName: project(meeting.projectID)?.name,
                                    summaryMarkdown: summaryMarkdown(for: meeting), notes: notes(for: meeting),
                                    transcript: transcript(for: meeting))
    }

    // MARK: - Search

    func search(_ query: String, in projectID: UUID?) -> [Meeting] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = meetings(in: projectID)
        guard !q.isEmpty else { return pool }
        let terms = q.split(separator: " ").map(String.init)
        return pool.filter { m in
            let text = searchableText(m)
            return terms.allSatisfy { text.contains($0) }
        }
    }

    private func searchableText(_ m: Meeting) -> String {
        if let t = textCache[m.id] { return t }
        var parts = [m.title]
        parts.append(contentsOf: m.actionItems.map { $0.task })
        parts.append(contentsOf: m.events.map { $0.title })
        if let s = summaryMarkdown(for: m) { parts.append(s) }
        parts.append(notes(for: m))
        parts.append(contentsOf: transcript(for: m).map { $0.text })
        let t = parts.joined(separator: "\n").lowercased()
        textCache[m.id] = t
        return t
    }

    // MARK: - Helpers

    private func uniqueURL(in dir: URL, base: String) -> URL {
        var candidate = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? jsonEncoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
