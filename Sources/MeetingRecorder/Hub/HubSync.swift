import Combine
import Foundation
import MeetingCore
import MeetingEngine
import MeetingSync

enum ProcessingMode: String { case local, hub }

enum StoreChange {
    case meeting(Meeting)
    case notes(Meeting)
    case deletedMeeting(UUID)
    case project(Project)
    case deletedProject(UUID)
}

/// What this Mac does with a hub beyond staying in sync with it (that part is `HubConnection`, shared with the
/// iOS app): getting a recording's audio there and asking for it to be processed, lining the projects in the
/// local folder up with the hub's the first time they meet, and the hub-side settings.
///
/// The local folder stays the UI's source of truth. A meeting that can't be uploaded because the hub is out of
/// reach waits in `uploading` and is retried until the hub answers; nothing is lost.
@MainActor
final class HubSync: ObservableObject {
    @Published private(set) var capabilities: Capabilities?
    @Published var hubSettings: HubSettings?
    @Published private(set) var migration: String?

    private let store: Store
    private let settings: AppSettings
    private weak var pipeline: Pipeline?
    private let replica: StoreReplica
    private let connection: HubConnection
    private var forwarding: AnyCancellable?

    init(store: Store, settings: AppSettings, pipeline: Pipeline) {
        self.store = store
        self.settings = settings
        self.pipeline = pipeline
        replica = StoreReplica(store: store)
        connection = HubConnection(replica: replica, ledgerURL: Self.ledgerURL)
        forwarding = connection.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        connection.prepare = { [weak self] client in await self?.prepare(client) }
        connection.onEvent = { [weak self] event in self?.handle(event) }
    }

    private static var ledgerURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MeetingRecorder/hub-ledger.json")
    }

    var state: HubConnection.State { connection.state }
    var whoAmI: WhoAmI? { connection.whoAmI }
    var lastSync: Date? { connection.lastSync }
    var client: HubClient? { connection.client }
    var isPaired: Bool { PairingCode(parsing: settings.hubPairingCode) != nil }
    var isEnabled: Bool { settings.mode == .hub && connection.client != nil }
    func isProcessing(_ id: UUID) -> Bool { replica.uploading.contains(id) }

    // MARK: - Connection

    /// Call once at launch and whenever the pairing code or mode changes.
    func configure() {
        if settings.mode == .hub, isPaired {
            connection.use(pairingCode: settings.hubPairingCode)
        } else {
            connection.disconnect()
        }
    }

    func connect() async { await connection.connect() }

    /// Validate a pairing code against the hub, then keep it and switch to hub mode.
    func pair(code: String) async throws -> WhoAmI {
        let me = try await HubConnection.validate(pairingCode: code)
        settings.hubPairingCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.processingMode = ProcessingMode.hub.rawValue
        configure()
        return me
    }

    func forget() {
        connection.disconnect()
        connection.engine.reset()
        settings.hubPairingCode = ""
        settings.processingMode = ProcessingMode.local.rawValue
        hubSettings = nil
        capabilities = nil
    }

    /// A pairing code for another of the user's devices, to show as a QR.
    func pairDevice(named name: String) async throws -> PairingCode {
        guard let client else { throw HubClientError.notPaired }
        return try await client.pairDevice(named: name)
    }

    private func prepare(_ client: HubClient) async {
        capabilities = try? await client.capabilities()
        hubSettings = try? await client.settings()
        await reconcileProjects(client)
    }

    private func handle(_ event: HubEvent) {
        switch event.kind {
        case .jobUpdated:
            // While this Mac is still uploading, the progress line is its own.
            guard let job = event.job, !replica.uploading.contains(job.meetingID) else { return }
            let running = job.status == .queued || job.status == .running
            pipeline?.setProgress(job.meetingID, running ? job.progress : nil)
        case .settingsUpdated:
            Task { [weak self] in
                guard let client = self?.client else { return }
                self?.hubSettings = try? await client.settings()
            }
        default:
            break
        }
    }

    // MARK: - Local edits

    func noteChange(_ change: StoreChange) {
        guard settings.mode == .hub else { return }
        switch change {
        case .meeting(let m), .notes(let m): connection.note(.meeting(m.id))
        case .deletedMeeting(let id): connection.note(.removedMeeting(id))
        case .project(let p): connection.note(.project(p.id))
        case .deletedProject(let id): connection.note(.removedProject(id))
        }
    }

    // MARK: - Projects

    /// Line up the projects in the local folder with the hub's. A local project with the same name as a hub
    /// project (and an id the hub doesn't know) takes the hub's id, so "Inbox" here and "Inbox" there are one
    /// project; any other project the hub hasn't got is sent to it.
    private func reconcileProjects(_ client: HubClient) async {
        guard let remote = try? await client.projects() else { return }
        let remoteIDs = Set(remote.map(\.id))
        for theirs in remote where store.project(theirs.id) == nil {
            guard let mine = store.projects.first(where: {
                !remoteIDs.contains($0.id) && !connection.engine.tracks(project: $0.id)
                    && $0.name.caseInsensitiveCompare(theirs.project.name) == .orderedSame
            }) else { continue }
            Log.hub.info("adopting hub id for project “\(mine.name)”")
            // The hub's copy is about to replace this one. Anything written here that the hub has no version
            // of goes up first, so adopting an id never costs the user their notes.
            let context = store.projectContext(mine.id), learned = store.learnedContext(mine.id)
            store.adoptProjectID(mine.id, newID: theirs.id)
            let patch = PatchProjectRequest(context: theirs.context.isEmpty && !context.isEmpty ? context : nil,
                                            learnedContext: theirs.learnedContext.isEmpty && !learned.isEmpty ? learned : nil)
            if patch.context != nil || patch.learnedContext != nil { _ = try? await client.patchProject(theirs.id, patch) }
        }
        for project in store.projects where !remoteIDs.contains(project.id) { connection.note(.project(project.id)) }
    }

    // MARK: - Processing

    func process(_ meeting: Meeting, steps: [JobStep]) {
        guard !replica.uploading.contains(meeting.id) else { return }
        replica.uploading.insert(meeting.id)
        Task { await self.processLoop(meeting.id, steps: steps) }
    }

    private func processLoop(_ id: UUID, steps requested: [JobStep]) async {
        defer {
            replica.uploading.remove(id)
            // The hub takes it from here; its status and results arrive like any other change.
            Task { await self.connection.sync() }
        }
        var attempt = 0
        while true {
            guard let client, store.meeting(id) != nil else { return }
            do {
                try await processOnce(id, steps: requested, client: client)
                return
            } catch let error where error.isConnectivityProblem {
                attempt += 1
                Log.hub.warning("hub unreachable while processing: \(error.localizedDescription)")
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
        guard let meeting = store.meeting(id) else { return }
        setStatus(id, .uploading, progress: "Preparing upload…")

        // Raw CAF captures are ~700 MB/hour; ship AAC instead.
        let tracks = await prepareTracks(meeting)

        // The meeting (and its project) have to exist on the hub before audio can be attached to them.
        connection.note(.project(meeting.projectID))
        connection.note(.newMeeting(id))
        try await connection.push()

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
    }

    /// Have the hub re-derive a project's learned note; the result comes down with the next sync.
    func refreshProjectContext(_ projectID: UUID) async throws {
        guard let client else { throw HubClientError.notPaired }
        _ = try await client.refreshProjectContext(projectID)
        await connection.sync()
    }

    /// Have the hub write "how would you handle this" for one action item. It keeps a copy, which every device
    /// gets by syncing; the text also comes back here for the caller that is waiting on it.
    func advise(item: UUID, in meetingID: UUID) async throws -> String {
        guard let client else { throw HubClientError.notPaired }
        return try await client.advise(meeting: meetingID, item: item).guidance
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

    private func setStatus(_ id: UUID, _ status: MeetingStatus, progress: String?) {
        if var m = store.meeting(id), m.status != status {
            m.status = status
            m.errorMessage = nil
            store.update(m)
        }
        pipeline?.setProgress(id, progress)
    }

    private func fail(_ id: UUID, _ message: String) {
        guard var m = store.meeting(id) else { return }
        m.status = .failed
        m.errorMessage = message
        store.update(m)
        pipeline?.setProgress(id, nil)
    }

    // MARK: - Migration of what's already on this Mac

    /// Copy meetings that were processed on this Mac — before there was a hub, or in local mode — to the hub,
    /// results and all, so other devices can see them.
    func uploadExistingMeetings() {
        guard migration == nil, isEnabled, let client else { return }
        Task {
            let meetings = store.meetings.filter { !replica.uploading.contains($0.id) && !connection.engine.tracks(meeting: $0.id) }
            var n = 0
            for m in meetings {
                n += 1
                migration = "\(n) of \(meetings.count): \(m.title)"
                do {
                    try await uploadWhole(m, client: client) { self.migration = "\(n) of \(meetings.count): \(m.title) — uploading audio" }
                } catch {
                    migration = "Stopped at “\(m.title)”: \(error.localizedDescription)"
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    migration = nil
                    return
                }
            }
            await connection.sync()
            migration = "Done — \(meetings.count) meetings are on the hub"
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            migration = nil
        }
    }

    private func uploadWhole(_ m: Meeting, client: HubClient, uploadingAudio: () -> Void) async throws {
        // Read everything before the first request. Once the hub has the meeting it starts arriving in syncs,
        // and the hub's (still empty) copy would replace what is about to be sent.
        let notes = store.notes(for: m)
        let transcript = store.transcript(for: m)
        let summary = store.summaryMarkdown(for: m)
        let tracks = await prepareTracks(m)

        connection.note(.project(m.projectID))
        try await connection.push()
        _ = try await client.createMeeting(CreateMeetingRequest(
            id: m.id, projectID: m.projectID, title: m.title, titleIsAuto: m.titleIsAuto, startedAt: m.startedAt,
            durationSeconds: m.durationSeconds, source: m.source, importedFileName: m.importedFileName))
        _ = try await client.patchMeeting(m.id, PatchMeetingRequest(
            title: m.titleIsAuto ? nil : m.title, titleIsAuto: m.titleIsAuto, notes: notes,
            speakerNames: m.speakerNames, events: m.events))
        _ = try await client.replaceActionItems(m.id, m.actionItems)

        let detail = try await client.meeting(m.id)
        if detail.transcript.isEmpty, !transcript.isEmpty { _ = try await client.pushTranscript(m.id, transcript) }
        if detail.summaryMarkdown == nil, let summary { _ = try await client.pushSummary(m.id, markdown: summary) }
        for (kind, url) in tracks {
            let sha = try await Task.detached { try HubClient.sha256(of: url) }.value
            if detail.audio.contains(where: { $0.kind == kind && $0.sha256 == sha }) { continue }
            uploadingAudio()
            _ = try await client.upload(m.id, kind: kind, file: url)
        }
        if m.status == .recorded || m.status == .failed, !tracks.isEmpty {
            process(m, steps: JobStep.allCases)
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
}
