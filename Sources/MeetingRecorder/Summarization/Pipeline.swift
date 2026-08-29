import Foundation

/// Runs recorded → transcribed → summarized, updating the meeting as it goes.
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
            case .recorded, .transcribing:
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
                let version = TranscriptionService.modelVersion(from: settings.asrVersion)
                try await service.prepare(version: version) { text in
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
            setProgress(id, "Summarizing with Claude (\(settings.claudeModel))…")
            do {
                let segments = store.transcript(for: meeting)
                let transcript = store.transcriptMarkdown(segments, meeting: meeting)
                let projectName = store.project(meeting.projectID)?.name
                let context = store.projectContext(meeting.projectID)
                let summarizer = ClaudeSummarizer(claudePath: settings.claudePath, model: settings.claudeModel)
                let summary = try await summarizer.summarize(
                    transcript: transcript, projectName: projectName, projectContext: context,
                    meeting: meeting, userName: settings.userName, workingDirectory: store.folder(for: meeting))

                guard var fresh = store.meeting(id) else { return }
                if fresh.titleIsAuto, let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    fresh.title = title
                }
                store.saveSummary(Prompts.renderSummary(summary, meeting: fresh, projectName: projectName), for: fresh)
                // Merge action items, preserving completion state of unchanged tasks.
                let existing = fresh.actionItems
                fresh.actionItems = summary.actionItems.filter { !$0.task.isEmpty }.map { item in
                    if let old = existing.first(where: { $0.task.caseInsensitiveCompare(item.task) == .orderedSame }) {
                        var kept = old; kept.owner = item.owner; kept.due = item.due; return kept
                    }
                    return ActionItem(task: item.task, owner: item.owner, due: item.due)
                }
                fresh.actionItems += existing.filter { old in
                    old.isManual && !fresh.actionItems.contains { $0.task.caseInsensitiveCompare(old.task) == .orderedSame }
                }
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
