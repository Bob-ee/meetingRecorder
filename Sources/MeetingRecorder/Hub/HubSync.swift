import Foundation
import MeetingCore
import MeetingEngine

enum ProcessingMode: String { case local, hub }

enum StoreChange {
    case meeting(Meeting)
    case notes(Meeting)
    case deletedMeeting(UUID)
    case project(Project)
    case deletedProject(UUID)
}

/// Keeps this Mac and the hub in step. The local folder stays the UI's source of truth; the hub does the
/// processing and holds the copy every other device sees.
///
/// * `process(_:steps:)` — upload audio, ask the hub to transcribe/summarize, mirror progress, pull the results.
///   Survives being offline: the meeting waits in `uploading` and retries until the hub answers.
/// * local edits (`noteChange`) are pushed as patches, debounced; if the push fails they stay dirty and retry.
/// * `pull()` brings in changes made elsewhere (phone, web, another Mac); server-sent events trigger it early.
@MainActor
final class HubSync: ObservableObject {
    enum State: Equatable {
        case off, connecting, connected, offline(String), rejected(String)

        var label: String {
            switch self {
            case .off: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .offline(let why): return "Hub unreachable — \(why)"
            case .rejected(let why): return why
            }
        }
        var isConnected: Bool { self == .connected }
    }

    @Published private(set) var state: State = .off
    @Published private(set) var whoAmI: WhoAmI?
    @Published private(set) var capabilities: Capabilities?
    @Published var hubSettings: HubSettings?
    @Published private(set) var migration: String?
    @Published private(set) var lastPull: Date?

    private let store: Store
    private let settings: AppSettings
    private weak var pipeline: Pipeline?
    private(set) var client: HubClient?

    private var eventTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var processing: Set<UUID> = []
    private var applyingRemote = false
    private var pullRequested = false

    private var dirtyMeetings: Set<UUID> { didSet { persist("hubDirtyMeetings", dirtyMeetings) } }
    private var dirtyProjects: Set<UUID> { didSet { persist("hubDirtyProjects", dirtyProjects) } }
    private var pendingDeletes: Set<UUID> { didSet { persist("hubPendingDeletes", pendingDeletes) } }

    init(store: Store, settings: AppSettings, pipeline: Pipeline) {
        self.store = store
        self.settings = settings
        self.pipeline = pipeline
        dirtyMeetings = Self.restore("hubDirtyMeetings")
        dirtyProjects = Self.restore("hubDirtyProjects")
        pendingDeletes = Self.restore("hubPendingDeletes")
    }

    var isEnabled: Bool { settings.mode == .hub && client != nil }
    func isProcessing(_ id: UUID) -> Bool { processing.contains(id) }

    // MARK: - Connection

    /// Call once at launch and whenever the pairing code or mode changes.
    func configure() {
        client = HubClient(pairingCode: settings.hubPairingCode)
        if settings.mode == .hub, client != nil {
            Task { await connect() }
        } else {
            disconnect()
        }
    }

    func connect() async {
        guard let client else { state = .off; return }
        state = .connecting
        do {
            let me = try await client.me()
            whoAmI = me
            state = .connected
            capabilities = try? await client.capabilities()
            hubSettings = try? await client.settings()
            startEventLoop()
            startPullLoop()
            await reconcileProjects()
            await pushDirty()
            await pull()
        } catch let error as HubClientError where error.isUnauthorized {
            state = .rejected("The hub rejected this pairing code — run `meetinghub pair` on the hub for a new one")
        } catch {
            state = .offline(error.localizedDescription)
            startPullLoop()   // keeps retrying the connection
        }
    }

    func disconnect() {
        eventTask?.cancel(); eventTask = nil
        pullTask?.cancel(); pullTask = nil
        state = .off
        whoAmI = nil
    }

    /// Validate a pairing code against the hub, then keep it and switch to hub mode.
    func pair(code: String) async throws -> WhoAmI {
        guard let candidate = HubClient(pairingCode: code) else { throw HubClientError.badURL }
        let me = try await candidate.me()
        settings.hubPairingCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.processingMode = ProcessingMode.hub.rawValue
        configure()
        return me
    }

    func forget() {
        disconnect()
        settings.hubPairingCode = ""
        settings.processingMode = ProcessingMode.local.rawValue
        client = nil
        hubSettings = nil
        capabilities = nil
    }

    private func startEventLoop() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let client = self.client else { return }
                do {
                    for try await event in client.events() {
                        await self.handle(event)
                    }
                } catch {}
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func startPullLoop() {
        pullTask?.cancel()
        pullTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                if self.state.isConnected {
                    await self.pushDirty()
                    await self.pull()
                } else if self.settings.mode == .hub {
                    await self.connect()
                    return   // connect() starts a fresh loop
                }
            }
        }
    }

    private func handle(_ event: HubEvent) async {
        switch event.kind {
        case .ping: return
        case .meetingUpdated, .projectUpdated, .projectDeleted:
            if let id = event.meetingID, processing.contains(id) { return }
            schedulePull()
        case .meetingDeleted:
            if let id = event.meetingID, store.meeting(id) != nil, !dirtyMeetings.contains(id) {
                applyingRemote = true
                store.deleteMeeting(id)
                applyingRemote = false
            }
        case .jobUpdated:
            return   // the processing loop polls its own job
        case .settingsUpdated:
            if let client { hubSettings = try? await client.settings() }
        }
    }

    private func schedulePull() {
        guard !pullRequested else { return }
        pullRequested = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.pullRequested = false
            await self.pull()
        }
    }

    private func markOffline(_ error: Error) {
        if error.isConnectivityProblem { state = .offline(error.localizedDescription) }
    }

    // MARK: - Processing

    func process(_ meeting: Meeting, steps: [JobStep]) {
        guard !processing.contains(meeting.id) else { return }
        processing.insert(meeting.id)
        Task { await self.processLoop(meeting.id, steps: steps) }
    }

    private func processLoop(_ id: UUID, steps requested: [JobStep]) async {
        defer { processing.remove(id); pipeline?.setProgress(id, nil) }
        var attempt = 0
        while true {
            guard let client, store.meeting(id) != nil else { return }
            do {
                try await processOnce(id, steps: requested, client: client)
                return
            } catch let error where error.isConnectivityProblem {
                attempt += 1
                Log.hub.warning("hub unreachable while processing: \(error.localizedDescription)")
                markOffline(error)
                setStatus(id, .uploading, progress: "Waiting for the hub — retrying (\(error.localizedDescription))")
                try? await Task.sleep(nanoseconds: UInt64(min(30 * attempt, 120)) * 1_000_000_000)
            } catch {
                Log.hub.error("hub processing failed: \(error.localizedDescription)")
                fail(id, error.localizedDescription)
                return
            }
        }
    }

    private func processOnce(_ id: UUID, steps requested: [JobStep], client: HubClient) async throws {
        guard var meeting = store.meeting(id) else { return }
        setStatus(id, .uploading, progress: "Preparing upload…")

        // Raw CAF captures are ~700 MB/hour; ship AAC instead.
        let tracks = await prepareTracks(meeting)
        meeting = store.meeting(id) ?? meeting

        try await ensureProjectOnHub(meeting.projectID, client: client)
        _ = try await client.createMeeting(CreateMeetingRequest(
            id: meeting.id, projectID: meeting.projectID, title: meeting.title, titleIsAuto: meeting.titleIsAuto,
            startedAt: meeting.startedAt, durationSeconds: meeting.durationSeconds, source: meeting.source,
            importedFileName: meeting.importedFileName))

        let already = try await client.audio(id)
        for (kind, url) in tracks {
            let sha = try await Task.detached { try HubClient.sha256(of: url) }.value
            if already.contains(where: { $0.kind == kind && $0.sha256 == sha }) { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            setStatus(id, .uploading, progress: "Uploading \(label(kind)) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))…")
            _ = try await client.upload(id, kind: kind, file: url)
        }

        var steps = requested
        if steps.contains(.transcribe), tracks.isEmpty {
            // Nothing to transcribe here (audio gone, or processed locally before): reuse the local transcript.
            let segments = store.transcript(for: meeting)
            guard !segments.isEmpty else { throw HubClientError.http(400, "there is no audio or transcript for this meeting") }
            _ = try await client.pushTranscript(id, segments)
            steps.removeAll { $0 == .transcribe }
            if steps.isEmpty { steps = [.summarize] }
        }
        _ = try await client.process(id, steps: steps)
        setStatus(id, .queued, progress: "Queued on \(whoAmI?.hub.name ?? "the hub")")

        // Follow the job until the hub is done, mirroring its state.
        while true {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let detail = try await client.meeting(id)
            guard store.meeting(id) != nil else { return }
            switch detail.meeting.status {
            case .ready:
                apply(detail)
                pipeline?.setProgress(id, nil)
                return
            case .failed:
                apply(detail)
                fail(id, detail.meeting.errorMessage ?? detail.job?.error ?? "The hub couldn't process this meeting")
                return
            case .queued, .transcribing, .summarizing, .transcribed:
                setStatus(id, detail.meeting.status, progress: detail.job?.progress)
            default:
                if let job = detail.job, job.status == .failed {
                    fail(id, job.error ?? "The hub couldn't process this meeting")
                    return
                }
                if let job = detail.job, job.status == .done {
                    apply(detail)
                    return
                }
            }
        }
    }

    /// Compress raw tracks and return what should be uploaded.
    private func prepareTracks(_ meeting: Meeting) async -> [(AudioTrackKind, URL)] {
        var result: [(AudioTrackKind, URL)] = []
        let folder = store.folder(for: meeting)
        for (kind, name) in [(AudioTrackKind.mic, "mic"), (.system, "system")] {
            let caf = folder.appendingPathComponent("\(name).caf")
            if FileManager.default.fileExists(atPath: caf.path) {
                setStatus(meeting.id, .uploading, progress: "Compressing \(label(kind))…")
                await Task.detached(priority: .userInitiated) { AudioArchiver.compressAndReplace(caf) }.value
            }
            if let url = store.existingTrackURL(name, for: meeting) { result.append((kind, url)) }
        }
        if let imported = store.importedURL(for: meeting), store.exists(imported) { result.append((.imported, imported)) }
        return result
    }

    private func label(_ kind: AudioTrackKind) -> String {
        switch kind {
        case .mic: return "your mic track"
        case .system: return "the other participants' track"
        case .imported: return "the recording"
        }
    }

    private func ensureProjectOnHub(_ projectID: UUID, client: HubClient) async throws {
        guard let project = store.project(projectID) else { return }
        if let remote = try? await client.projects(), !remote.contains(where: { $0.project.id == project.id }),
           remote.contains(where: { $0.project.name.caseInsensitiveCompare(project.name) == .orderedSame }) {
            await reconcileProjects()
            return
        }
        _ = try await client.createProject(CreateProjectRequest(id: project.id, name: project.name, context: store.projectContext(project.id)))
    }

    private func setStatus(_ id: UUID, _ status: MeetingStatus, progress: String?) {
        if var m = store.meeting(id), m.status != status {
            m.status = status
            m.errorMessage = nil
            applyingRemote = true
            store.update(m)
            applyingRemote = false
        }
        pipeline?.setProgress(id, progress)
    }

    private func fail(_ id: UUID, _ message: String) {
        guard var m = store.meeting(id) else { return }
        m.status = .failed
        m.errorMessage = message
        applyingRemote = true
        store.update(m)
        applyingRemote = false
        pipeline?.setProgress(id, nil)
    }

    // MARK: - Applying what the hub has

    private func apply(_ detail: MeetingDetail) {
        applyingRemote = true
        defer { applyingRemote = false }
        let remote = detail.meeting
        guard var local = store.meeting(remote.id) else { return }
        let dirty = dirtyMeetings.contains(remote.id)
        if !dirty {
            local.title = remote.title
            local.titleIsAuto = remote.titleIsAuto
            local.speakerNames = remote.speakerNames
            local.actionItems = remote.actionItems
        } else {
            // Keep our unsent edits, but take new items the hub found.
            local.actionItems = ActionItems.merge(existing: local.actionItems, fresh: remote.actionItems.map { MeetingSummary.Item(owner: $0.owner, task: $0.task, due: $0.due) })
        }
        local.status = remote.status
        local.errorMessage = remote.errorMessage
        if remote.durationSeconds > 0 { local.durationSeconds = remote.durationSeconds }
        store.update(local)
        if !detail.transcript.isEmpty { store.saveTranscript(detail.transcript, for: local) }
        if let md = detail.summaryMarkdown { store.saveSummary(md, for: local) }
        if !dirty, !detail.notes.isEmpty, detail.notes != store.notes(for: local) { store.saveNotes(detail.notes, for: local) }
    }

    private func createLocal(from detail: MeetingDetail) {
        applyingRemote = true
        defer { applyingRemote = false }
        let remote = detail.meeting
        if store.project(remote.projectID) == nil {
            store.createProject(id: remote.projectID, name: detail.projectName)
        }
        _ = store.createMeeting(id: remote.id, in: remote.projectID, title: remote.title, source: remote.source, startedAt: remote.startedAt)
        applyingRemote = false
        apply(detail)
    }

    // MARK: - Projects

    /// Line up projects on both sides. A local project with the same name as a hub project (and an id the hub
    /// doesn't know) takes the hub's id, so "Inbox" here and "Inbox" there are one project. Everything else is
    /// created on whichever side is missing it.
    func reconcileProjects() async {
        guard isEnabled, let client else { return }
        do {
            let remote = try await client.projects()
            let remoteIDs = Set(remote.map(\.project.id))
            applyingRemote = true
            for rp in remote {
                if store.project(rp.project.id) != nil { continue }
                if let local = store.projects.first(where: { !remoteIDs.contains($0.id) && $0.name.caseInsensitiveCompare(rp.project.name) == .orderedSame }) {
                    Log.hub.info("adopting hub id for project “\(local.name)”")
                    store.adoptProjectID(local.id, newID: rp.project.id)
                    dirtyProjects.remove(local.id)
                    if store.projectContext(rp.project.id).isEmpty, !rp.context.isEmpty { store.setProjectContext(rp.project.id, rp.context) }
                } else {
                    store.createProject(id: rp.project.id, name: rp.project.name)
                    if !rp.context.isEmpty { store.setProjectContext(rp.project.id, rp.context) }
                }
            }
            applyingRemote = false
            for p in store.projects where !remoteIDs.contains(p.id) {
                _ = try await client.createProject(CreateProjectRequest(id: p.id, name: p.name, context: store.projectContext(p.id)))
            }
        } catch {
            applyingRemote = false
            Log.hub.error("project reconcile failed: \(error.localizedDescription)")
            markOffline(error)
        }
    }

    // MARK: - Pull

    func pull() async {
        guard isEnabled, let client, state.isConnected else { return }
        do {
            let remoteProjects = try await client.projects()
            applyingRemote = true
            for rp in remoteProjects where store.project(rp.project.id) == nil && !dirtyProjects.contains(rp.project.id) {
                if store.projects.contains(where: { $0.name.caseInsensitiveCompare(rp.project.name) == .orderedSame }) {
                    applyingRemote = false
                    await reconcileProjects()   // a same-named project appeared; merge instead of duplicating
                    applyingRemote = true
                    continue
                }
                store.createProject(id: rp.project.id, name: rp.project.name)
                if !rp.context.isEmpty { store.setProjectContext(rp.project.id, rp.context) }
            }
            applyingRemote = false

            let since = settings.hubLastSync > 0 ? Date(timeIntervalSince1970: settings.hubLastSync - 300) : nil
            let remote = try await client.meetings(since: since)
            for rm in remote where !processing.contains(rm.id) && !pendingDeletes.contains(rm.id) {
                if let local = store.meeting(rm.id) {
                    guard rm.updatedAt > local.updatedAt.addingTimeInterval(1), !dirtyMeetings.contains(rm.id) else { continue }
                    let detail = try await client.meeting(rm.id)
                    apply(detail)
                } else if rm.status == .ready || rm.status == .failed || since != nil {
                    let detail = try await client.meeting(rm.id)
                    createLocal(from: detail)
                }
            }
            settings.hubLastSync = Date().timeIntervalSince1970
            lastPull = Date()
        } catch {
            applyingRemote = false
            Log.hub.error("pull failed: \(error.localizedDescription)")
            markOffline(error)
        }
    }

    // MARK: - Push (local edits → hub)

    func noteChange(_ change: StoreChange) {
        guard settings.mode == .hub, !applyingRemote else { return }
        switch change {
        case .meeting(let m): dirtyMeetings.insert(m.id)
        case .notes(let m): dirtyMeetings.insert(m.id)
        case .deletedMeeting(let id): dirtyMeetings.remove(id); pendingDeletes.insert(id)
        case .project(let p): dirtyProjects.insert(p.id)
        case .deletedProject(let id):
            dirtyProjects.remove(id)
            if let client { Task { try? await client.deleteProject(id) } }
        }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushDirty()
        }
    }

    func pushDirty() async {
        guard isEnabled, let client else { return }
        for id in pendingDeletes {
            do { try await client.deleteMeeting(id); pendingDeletes.remove(id) }
            catch let e as HubClientError where !e.isConnectivityProblem { pendingDeletes.remove(id) }   // already gone
            catch { Log.hub.error("delete push failed: \(error.localizedDescription)"); markOffline(error); return }
        }
        for id in dirtyProjects {
            guard let p = store.project(id) else { dirtyProjects.remove(id); continue }
            do {
                _ = try await client.createProject(CreateProjectRequest(id: p.id, name: p.name, context: store.projectContext(p.id)))
                _ = try await client.patchProject(p.id, PatchProjectRequest(name: p.name, context: store.projectContext(p.id)))
                dirtyProjects.remove(id)
            } catch { Log.hub.error("project push failed: \(error.localizedDescription)"); markOffline(error); return }
        }
        for id in dirtyMeetings {
            guard let m = store.meeting(id) else { dirtyMeetings.remove(id); continue }
            do {
                try await push(m, client: client)
                dirtyMeetings.remove(id)
            } catch { Log.hub.error("push of “\(m.title)” failed: \(error.localizedDescription)"); markOffline(error); return }
        }
    }

    private func push(_ m: Meeting, client: HubClient) async throws {
        try await ensureProjectOnHub(m.projectID, client: client)
        _ = try await client.createMeeting(CreateMeetingRequest(
            id: m.id, projectID: m.projectID, title: m.title, titleIsAuto: m.titleIsAuto, startedAt: m.startedAt,
            durationSeconds: m.durationSeconds, source: m.source, importedFileName: m.importedFileName))
        _ = try await client.patchMeeting(m.id, PatchMeetingRequest(
            title: m.titleIsAuto ? nil : m.title, titleIsAuto: m.titleIsAuto, projectID: m.projectID,
            notes: store.notes(for: m), speakerNames: m.speakerNames, durationSeconds: m.durationSeconds))
        _ = try await client.replaceActionItems(m.id, m.actionItems)
    }

    // MARK: - Migration of what's already on this Mac

    func uploadExistingMeetings() {
        guard migration == nil, isEnabled, let client else { return }
        Task {
            let meetings = store.meetings.filter { !processing.contains($0.id) }
            var n = 0
            for m in meetings {
                n += 1
                migration = "\(n) of \(meetings.count): \(m.title)"
                do {
                    try await push(m, client: client)
                    let detail = try await client.meeting(m.id)
                    let transcript = store.transcript(for: m)
                    if detail.transcript.isEmpty, !transcript.isEmpty { _ = try await client.pushTranscript(m.id, transcript) }
                    if detail.summaryMarkdown == nil, let md = store.summaryMarkdown(for: m) { _ = try await client.pushSummary(m.id, markdown: md) }
                    let tracks = await prepareTracks(m)
                    let already = detail.audio
                    for (kind, url) in tracks {
                        let sha = try await Task.detached { try HubClient.sha256(of: url) }.value
                        if already.contains(where: { $0.kind == kind && $0.sha256 == sha }) { continue }
                        migration = "\(n) of \(meetings.count): \(m.title) — uploading audio"
                        _ = try await client.upload(m.id, kind: kind, file: url)
                    }
                    if m.status == .recorded || m.status == .failed, !tracks.isEmpty {
                        process(m, steps: JobStep.allCases)
                    }
                } catch {
                    migration = "Stopped at “\(m.title)”: \(error.localizedDescription)"
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    migration = nil
                    return
                }
            }
            migration = "Done — \(meetings.count) meetings are on the hub"
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            migration = nil
        }
    }

    // MARK: - Hub settings

    func saveHubSettings(_ s: HubSettings) async throws {
        guard let client else { throw HubClientError.notPaired }
        var toSave = s
        toSave.userName = settings.userName
        toSave.asrVersion = settings.asrVersion
        hubSettings = try await client.saveSettings(toSave)
    }

    func testHubSettings(_ s: HubSettings) async throws -> TestResult {
        guard let client else { throw HubClientError.notPaired }
        var toTest = s
        toTest.userName = settings.userName
        return try await client.testSettings(toTest)
    }

    // MARK: - Persistence of unsent work

    private func persist(_ key: String, _ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: key)
    }

    private static func restore(_ key: String) -> Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }
}
