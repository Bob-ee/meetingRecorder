import Combine
import Foundation
import MeetingCore
import MeetingSync
import SwiftUI

/// Where the pieces are put together: the library, the connection that keeps it in step with the hub, the
/// recorder, and the uploader that gets recordings there.
@MainActor
final class AppModel: ObservableObject {
    /// One for the whole process. The system can launch the app in the background, with no window, to hand
    /// back the results of an upload — the uploader has to exist then too.
    static let shared = AppModel()

    let library: Library
    let connection: HubConnection
    let recorder: Recorder
    let uploader: Uploader

    @Published private(set) var isPaired = false
    /// What the hub says it is doing with each meeting right now ("Transcribing… 40%").
    @Published private(set) var jobProgress: [UUID: String] = [:]
    /// Action items whose "how would you handle this" request is in flight.
    @Published private(set) var advising: Set<UUID> = []
    @Published var adviceErrors: [UUID: String] = [:]
    /// Something the user should be told about: a failed import, a failed request.
    @Published var alert: String?
    /// The project the recording in progress will go into.
    @Published var recordingProjectID: UUID?

    private let recordings: URL
    private var watchers: Set<AnyCancellable> = []
    private static let pairingAccount = "hub-pairing-code"

    private init() {
        let support = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        recordings = support.appendingPathComponent("recordings", isDirectory: true)
        library = Library(directory: support)
        connection = HubConnection(replica: library, ledgerURL: support.appendingPathComponent("sync-ledger.json"))
        recorder = Recorder(directory: recordings)
        uploader = Uploader(directory: recordings)

        library.onChange = { [weak self] in self?.connection.note($0) }
        uploader.client = { [weak self] in self?.connection.client }
        uploader.onDelivered = { [weak self] _ in self?.syncNow() }
        recorder.onFinished = { [weak self] in self?.finished($0) }
        connection.onEvent = { [weak self] in self?.heard($0) }
        // Recordings made while the hub was out of reach go as soon as it answers.
        connection.$state.filter(\.isConnected)
            .sink { [weak self] _ in self?.uploader.resume() }
            .store(in: &watchers)

        if let code = Keychain.read(Self.pairingAccount) {
            isPaired = true
            connection.use(pairingCode: code)
        }
    }

    // MARK: - Pairing

    /// Check a pairing code against its hub, then keep it.
    func pair(code: String) async throws {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let me = try await HubConnection.validate(pairingCode: code)
        guard me.hub.apiVersion >= HubAPI.version else { throw PairingError.hubTooOld }
        guard Keychain.write(code, to: Self.pairingAccount) else { throw PairingError.keychain }
        isPaired = true
        connection.use(pairingCode: code)
    }

    /// Forget the hub and everything that came from it. Recordings still waiting to upload go too.
    func unpair() {
        connection.disconnect()
        connection.engine.reset()
        uploader.cancelAll()
        library.wipe()
        Keychain.delete(Self.pairingAccount)
        jobProgress = [:]
        isPaired = false
    }

    // MARK: - Lifecycle

    func open(_ url: URL) {
        if url.isFileURL {
            importRecording(url)
        } else if let code = PairingCode(url: url) {
            Task {
                do { try await pair(code: code.string) }
                catch { alert = "Couldn't pair with the hub: \(error.localizedDescription)" }
            }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard isPaired else { return }
            // The connection's own loops were frozen with the app; don't wait for them to notice.
            if connection.state.isConnected { syncNow() } else { Task { await connection.connect() } }
            uploader.resume()
        case .background:
            library.flush()
            connection.engine.save()
        default:
            break
        }
    }

    func syncNow() {
        Task { await connection.sync() }
    }

    private func heard(_ event: HubEvent) {
        guard event.kind == .jobUpdated, let job = event.job else { return }
        jobProgress[job.meetingID] = job.status == .queued || job.status == .running ? job.progress : nil
    }

    // MARK: - Recording and importing

    /// The project a new recording goes into unless the user picks another: the one they used last.
    var defaultProjectID: UUID? {
        if let last = UserDefaults.standard.string(forKey: "lastProjectID").flatMap(UUID.init(uuidString:)),
           library.project(last) != nil { return last }
        return library.inbox?.id
    }

    func startRecording(in projectID: UUID?) {
        recordingProjectID = projectID ?? defaultProjectID
        Task { await recorder.start() }
    }

    private func finished(_ recording: Recording) {
        guard let projectID = recordingProjectID.flatMap({ library.project($0)?.id }) ?? defaultProjectID else {
            alert = "The recording was kept, but there is no project to put it in yet — sync with the hub first."
            return
        }
        UserDefaults.standard.set(projectID.uuidString, forKey: "lastProjectID")
        let meeting = library.createMeeting(id: recording.id, in: projectID, title: "Meeting", source: .live,
                                            startedAt: recording.startedAt, duration: recording.duration)
        uploader.enqueue(meeting, file: recording.file)
    }

    /// Take in a recording made elsewhere — shared into the app, or picked from Files.
    func importRecording(_ url: URL, into projectID: UUID? = nil) {
        guard let projectID = projectID ?? defaultProjectID else {
            alert = "Pair with your hub before importing recordings."
            return
        }
        Task {
            do {
                let id = UUID()
                let staged = try await AudioImport.stage(url, as: id, in: recordings)
                let title = (staged.originalName as NSString).deletingPathExtension
                let meeting = library.createMeeting(id: id, in: projectID, title: title, source: .imported,
                                                    startedAt: staged.recordedAt, duration: staged.duration,
                                                    importedFileName: staged.originalName)
                uploader.enqueue(meeting, file: staged.file)
            } catch {
                alert = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func delete(meeting id: UUID) {
        uploader.cancel(id)
        library.deleteMeeting(id)
    }

    // MARK: - Things only the hub can do

    /// Have the hub transcribe and/or summarize a meeting again.
    func reprocess(_ meetingID: UUID, steps: [JobStep]) {
        request("Couldn't start processing") { client in _ = try await client.process(meetingID, steps: steps) }
    }

    /// Have the hub rewrite a project's learned note from its most recent meeting.
    func refreshContext(of projectID: UUID) {
        request("Couldn't rewrite the project note") { client in _ = try await client.refreshProjectContext(projectID) }
    }

    /// "How would you handle this?" for one action item — only ever on the user's say-so.
    func requestGuidance(for itemID: UUID, in meetingID: UUID) {
        guard !advising.contains(itemID), let client = connection.client else { return }
        advising.insert(itemID)
        adviceErrors[itemID] = nil
        Task {
            defer { advising.remove(itemID) }
            do {
                _ = try await client.advise(meeting: meetingID, item: itemID)
                await connection.sync()   // the advice arrives with the meeting
            } catch {
                adviceErrors[itemID] = error.localizedDescription
            }
        }
    }

    private func request(_ failure: String, _ call: @escaping (HubClient) async throws -> Void) {
        guard let client = connection.client else { alert = "\(failure): not connected to the hub."; return }
        Task {
            do {
                try await call(client)
                await connection.sync()
            } catch {
                alert = "\(failure): \(error.localizedDescription)"
            }
        }
    }
}

enum PairingError: LocalizedError {
    case hubTooOld, keychain

    var errorDescription: String? {
        switch self {
        case .hubTooOld: return "This hub is older than the app — update it by running the installer on it again."
        case .keychain: return "Couldn't save the pairing code on this device."
        }
    }
}
