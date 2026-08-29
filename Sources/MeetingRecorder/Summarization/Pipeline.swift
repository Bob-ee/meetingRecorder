import Foundation
import MeetingCore
import MeetingEngine

/// Local processing: recorded → transcribed → summarized on this Mac, updating the meeting as it goes.
/// (Hub mode hands the same steps to the hub instead.)
@MainActor
final class Pipeline: ObservableObject {
    @Published private(set) var progress: [UUID: String] = [:]
    private var running: Set<UUID> = []
    private let store: Store
    private let settings: AppSettings

    init(store: Store, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    func run(_ meeting: Meeting, transcribe: Bool = true, summarize: Bool = true) {
        guard !running.contains(meeting.id) else { return }
        running.insert(meeting.id)
        Task { await self.execute(meeting, transcribe: transcribe, summarize: summarize) }
    }

    /// Re-run anything that was interrupted (app quit mid-pipeline) on launch.
    func resumeUnfinished() {
        for m in store.meetings {
            switch m.status {
            case .recording:
                var fixed = m
                fixed.status = .recorded
                store.update(fixed)
                run(fixed)
            case .recorded, .queued, .transcribing:
                run(m, transcribe: true, summarize: true)
            case .transcribed, .summarizing:
                run(m, transcribe: !store.hasTranscript(m), summarize: true)
            default:
                break
            }
        }
    }

    func setProgress(_ id: UUID, _ text: String?) {
        if let text { progress[id] = text } else { progress.removeValue(forKey: id) }
    }

    private func execute(_ input: Meeting, transcribe: Bool, summarize: Bool) async {
        defer { running.remove(input.id); setProgress(input.id, nil) }
        guard var meeting = store.meeting(input.id) else { return }
        let id = meeting.id

        if transcribe {
            meeting.status = .transcribing
            meeting.errorMessage = nil
            store.update(meeting)
            do {
                let service = TranscriptionService.shared
                await service.setModelVersion(settings.asrVersion)
                try await service.prepare { text in
                    Task { @MainActor in self.setProgress(id, text) }
                }
                let micURL = meeting.source == .live ? store.existingTrackURL("mic", for: meeting) : nil
                let remoteURL = store.remoteAudioURL(for: meeting)
                let segments = try await service.transcribe(micURL: micURL, remoteURL: remoteURL, userLabel: settings.userName) { text in
                    Task { @MainActor in self.setProgress(id, text) }
                }
                guard var fresh = store.meeting(id) else { return }
                store.saveTranscript(segments, for: fresh)
                fresh.status = .transcribed
                store.update(fresh)
                meeting = fresh
                // Raw float CAF tracks are huge (~700 MB/hour each); shrink them to AAC now that we have the transcript.
                let toCompress = [store.micURL(for: fresh), store.systemURL(for: fresh)].filter { FileManager.default.fileExists(atPath: $0.path) }
                if !toCompress.isEmpty {
                    Task.detached(priority: .utility) {
                        for url in toCompress { AudioArchiver.compressAndReplace(url) }
                    }
                }
            } catch {
                guard var fresh = store.meeting(id) else { return }
                fresh.status = .failed
                fresh.errorMessage = "Transcription failed: \(error.localizedDescription)"
                store.update(fresh)
                return
            }
        }

        if summarize {
            guard store.hasTranscript(meeting) else {
                meeting.status = .failed
                meeting.errorMessage = "No transcript to summarize"
                store.update(meeting)
                return
            }
            meeting.status = .summarizing
            meeting.errorMessage = nil
            store.update(meeting)
            do {
                let summarizer = try SummarizerFactory.make(settings.summarizerSettings)
                setProgress(id, "Summarizing with \(summarizer.displayName)…")
                let segments = store.transcript(for: meeting)
                let request = SummaryRequest(
                    transcriptMarkdown: MeetingDocuments.transcriptMarkdown(segments, meeting: meeting),
                    projectName: store.project(meeting.projectID)?.name,
                    projectContext: store.projectContext(meeting.projectID),
                    meeting: meeting, userName: settings.userName,
                    debugDirectory: store.folder(for: meeting))
                let summary = try await summarizer.summarize(request)

                guard var fresh = store.meeting(id) else { return }
                if fresh.titleIsAuto, let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    fresh.title = title
                }
                store.saveSummary(Prompts.renderSummary(summary, meeting: fresh, projectName: request.projectName), for: fresh)
                fresh.actionItems = ActionItems.merge(existing: fresh.actionItems, fresh: summary.actionItems)
                fresh.status = .ready
                fresh.errorMessage = nil
                store.update(fresh)
                // The title may have changed; keep transcript.md's header in sync.
                store.saveTranscript(segments, for: fresh)
            } catch {
                guard var fresh = store.meeting(id) else { return }
                fresh.status = .failed
                fresh.errorMessage = "Summary failed: \(error.localizedDescription)"
                store.update(fresh)
            }
        }
    }
}
