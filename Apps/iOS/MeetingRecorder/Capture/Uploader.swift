import Foundation
import MeetingCore
import MeetingSync

/// Gets recordings to the hub, however long that takes.
///
/// Uploads run on a background `URLSession`, which belongs to the system rather than to the app: it keeps
/// going when the app is suspended or killed, and waits out a missing network by itself. Each request is the
/// whole job — it tells the hub to create the meeting if it hasn't got it, stores the audio, and queues the
/// transcription — because nothing guarantees the app will be running to send a second one.
///
/// What is waiting to go is kept in `outbox.json`, so a recording survives a restart of the app or the phone.
@MainActor
final class Uploader: NSObject, ObservableObject {
    struct Pending: Codable, Identifiable {
        var meeting: CreateMeetingRequest
        var fileName: String
        var attempts = 0
        var lastError: String?
        var id: UUID { meeting.id! }
    }

    enum State: Equatable {
        case waiting
        case uploading(Double)
        case failed(String)
    }

    @Published private(set) var outbox: [Pending] = []
    /// Fraction sent, for the uploads that are under way.
    @Published private(set) var progress: [UUID: Double] = [:]

    /// The hub to upload to; nil while the device isn't paired.
    var client: () -> HubClient? = { nil }
    /// A recording arrived at the hub.
    var onDelivered: ((UUID) -> Void)?
    /// Handed over by the system when it wakes the app to deliver results; to be called once they're handled.
    var backgroundEventsCompletion: (() -> Void)?

    private let directory: URL
    private let outboxFile: URL
    private var starting: Set<UUID> = []
    private var replies: [Int: Data] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "local.meetingrecorder.ios.uploads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // The delegate is called on the main queue, so its callbacks can touch this object directly.
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// `directory` holds the audio files; the outbox sits next to it.
    init(directory: URL) {
        self.directory = directory
        outboxFile = directory.deletingLastPathComponent().appendingPathComponent("outbox.json")
        super.init()
        if let data = try? Data(contentsOf: outboxFile), let saved = try? jsonDecoder.decode([Pending].self, from: data) {
            outbox = saved
        }
        // Reattach to whatever the system kept running while the app wasn't.
        _ = session
    }

    func state(for meetingID: UUID) -> State? {
        guard let entry = outbox.first(where: { $0.id == meetingID }) else { return nil }
        if let sent = progress[meetingID] { return .uploading(sent) }
        if let error = entry.lastError { return .failed(error) }
        return .waiting
    }

    /// Queue a recording. `file` must be inside this uploader's directory.
    func enqueue(_ meeting: Meeting, file: URL) {
        let request = CreateMeetingRequest(
            id: meeting.id, projectID: meeting.projectID, title: meeting.title, titleIsAuto: meeting.titleIsAuto,
            startedAt: meeting.startedAt, durationSeconds: meeting.durationSeconds, source: meeting.source,
            importedFileName: meeting.importedFileName)
        outbox.append(Pending(meeting: request, fileName: file.lastPathComponent))
        save()
        resume()
    }

    /// Start every upload that isn't already under way. Cheap to call — on launch, when the hub connects,
    /// when the app comes to the front.
    func resume() {
        guard let client = client(), !outbox.isEmpty else { return }
        Task {
            let running = Set(await session.allTasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
            for entry in outbox where !running.contains(entry.id) && !starting.contains(entry.id) {
                start(entry, with: client)
            }
        }
    }

    /// Give up on a recording: stop its upload and delete the audio.
    func cancel(_ meetingID: UUID) {
        guard outbox.contains(where: { $0.id == meetingID }) else { return }
        Task {
            for task in await session.allTasks where task.taskDescription == meetingID.uuidString { task.cancel() }
        }
        finish(meetingID, deletingFile: true)
    }

    func cancelAll() {
        for entry in outbox { cancel(entry.id) }
    }

    private func start(_ entry: Pending, with client: HubClient) {
        let id = entry.id
        let file = directory.appendingPathComponent(entry.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            finish(id, deletingFile: false)
            return
        }
        starting.insert(id)
        update(id) { $0.attempts += 1 }
        progress[id] = 0
        Task {
            defer { starting.remove(id) }
            do {
                // A phone recording is one track with everyone in it, which is what the hub calls an import:
                // it works out who is speaking rather than assuming the whole track is the owner's voice.
                // Building the request hashes the file, so it happens off the main thread.
                let request = try await Task.detached {
                    try client.uploadRequest(id, kind: .imported, file: file, creating: entry.meeting, process: JobStep.allCases)
                }.value
                let task = session.uploadTask(with: request, fromFile: file)
                task.taskDescription = id.uuidString
                task.resume()
            } catch {
                fail(id, error.localizedDescription)
            }
        }
    }

    private func fail(_ id: UUID, _ message: String) {
        progress[id] = nil
        update(id) { $0.lastError = message }
    }

    private func finish(_ id: UUID, deletingFile: Bool) {
        if deletingFile, let entry = outbox.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
        }
        progress[id] = nil
        outbox.removeAll { $0.id == id }
        save()
    }

    private func update(_ id: UUID, _ change: (inout Pending) -> Void) {
        guard let i = outbox.firstIndex(where: { $0.id == id }) else { return }
        change(&outbox[i])
        save()
    }

    private func save() {
        do {
            try wireEncoder.encode(outbox).write(to: outboxFile, options: .atomic)
        } catch {
            Log.hub.error("couldn't save the upload outbox: \(error.localizedDescription)")
        }
    }

    // MARK: - What the session reports

    private func completed(_ task: URLSessionTask, error: Error?) {
        let reply = replies.removeValue(forKey: task.taskIdentifier) ?? Data()
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)), outbox.contains(where: { $0.id == id }) else { return }
        if let error {
            // Cancelled means `cancel` already dealt with it.
            if (error as? URLError)?.code != .cancelled { fail(id, error.localizedDescription) }
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        switch HubClient.error(status: status, body: reply) {
        case nil:
            Log.hub.info("uploaded recording \(id.uuidString.prefix(8))")
            finish(id, deletingFile: true)
            onDelivered?(id)
        case let refusal? where refusal.isGone:
            // The meeting was deleted on another device while this was on its way.
            finish(id, deletingFile: true)
        case let refusal?:
            fail(id, refusal.localizedDescription)
        }
    }
}

extension Uploader: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                                totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let sent = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        MainActor.assumeIsolated {
            if let id = task.taskDescription.flatMap(UUID.init(uuidString:)) { progress[id] = sent }
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated { replies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { completed(task, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundEventsCompletion?()
            backgroundEventsCompletion = nil
        }
    }
}
