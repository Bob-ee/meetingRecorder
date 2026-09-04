import Foundation
import MeetingCore
import MeetingEngine

/// Local processing: recorded → transcribed → summarized on this Mac, updating the meeting as it goes.
/// (Hub mode hands the same steps to the hub instead.)
@MainActor
final class Pipeline: ObservableObject {
    @Published private(set) var progress: [UUID: String] = [:]
    /// Action items whose "how would you handle this" request is in flight.
    @Published private(set) var advising: Set<UUID> = []
    /// The last advice failure per action item, cleared when a new request starts.
    @Published var adviceErrors: [UUID: String] = [:]
    /// Projects whose context is being rewritten.
    @Published private(set) var updatingContext: Set<UUID> = []
    private var running: Set<UUID> = []
    private let store: Store
    private let settings: AppSettings
    /// Set when a hub is paired; in hub mode all work goes there.
    weak var hub: HubSync?

    init(store: Store, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func isRunning(_ id: UUID) -> Bool { running.contains(id) || (hub?.isProcessing(id) ?? false) }

    func run(_ meeting: Meeting, transcribe: Bool = true, summarize: Bool = true) {
        if let hub, settings.mode == .hub, hub.isEnabled {
            var steps: [JobStep] = []
            if transcribe { steps.append(.transcribe) }
            if summarize { steps.append(.summarize) }
            hub.process(meeting, steps: steps)
            return
        }
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
            case .recorded, .uploading, .queued, .transcribing:
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
                let contexts = store.contexts(meeting.projectID)
                let openItems = store.openProjectItems(for: meeting)
                let request = SummaryRequest(
                    transcriptMarkdown: MeetingDocuments.transcriptMarkdown(segments, meeting: meeting),
                    projectName: store.project(meeting.projectID)?.name,
                    projectContext: contexts.user, learnedContext: contexts.learned, openProjectItems: openItems,
                    meeting: meeting, userName: settings.userName,
                    debugDirectory: store.folder(for: meeting))
                let summary = try await summarizer.summarize(request)

                guard var fresh = store.meeting(id) else { return }
                if fresh.titleIsAuto, let title = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    fresh.title = title
                }
                // Anything this meeting restated or finished belongs to the meeting that raised it, not to this one.
                let carried = ActionItems.carryForward(
                    pairs: summary.resolvedActionItemPairs(for: fresh), completed: summary.completedItems,
                    openItems: openItems, itemsByID: store.itemsByID(in: fresh.projectID), meetingID: fresh.id)
                let freshItems = carried.items
                let freshEvents = summary.resolvedEvents(for: fresh)
                let markdown = Prompts.renderSummary(summary, meeting: fresh, projectName: request.projectName,
                                                     actionItems: freshItems, events: freshEvents)
                store.saveSummary(markdown, for: fresh)
                fresh.actionItems = ActionItems.merge(existing: fresh.actionItems, fresh: freshItems)
                fresh.events = MeetingEvents.merge(existing: fresh.events, fresh: freshEvents)
                fresh.status = .ready
                fresh.errorMessage = nil
                store.update(fresh)
                store.applyCarriedEdits(carried.edits)
                // The title may have changed; keep transcript.md's header in sync.
                store.saveTranscript(segments, for: fresh)
                await updateProjectContext(for: fresh, summarizer: summarizer, summaryMarkdown: markdown)
            } catch {
                guard var fresh = store.meeting(id) else { return }
                fresh.status = .failed
                fresh.errorMessage = "Summary failed: \(error.localizedDescription)"
                store.update(fresh)
            }
        }
    }

    // MARK: - Project context

    /// Bring the project's learned note up to date after a meeting. A failure here is deliberately non-fatal:
    /// the meeting is already summarized, and a stale note is a much smaller problem than a failed meeting.
    private func updateProjectContext(for meeting: Meeting, summarizer: any Summarizer, summaryMarkdown: String) async {
        guard let project = store.project(meeting.projectID) else { return }
        updatingContext.insert(project.id)
        defer { updatingContext.remove(project.id) }
        setProgress(meeting.id, "Updating project context…")
        let contexts = store.contexts(project.id)
        do {
            let update = try await summarizer.updateContext(ContextUpdateRequest(
                projectName: project.name, userContext: contexts.user, learnedContext: contexts.learned,
                meeting: meeting, summaryMarkdown: summaryMarkdown, debugDirectory: store.folder(for: meeting)))
            guard let update else { return }
            let text = update.context.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != contexts.learned else { return }
            store.setLearnedContext(project.id, text, note: Self.contextNote(update, meeting: meeting))
            Log.pipeline.info("project context updated after “\(meeting.title)”")
        } catch {
            Log.pipeline.warning("project context update failed: \(error.localizedDescription)")
        }
    }

    private static func contextNote(_ update: ContextUpdate, meeting: Meeting) -> String {
        let what = update.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = Fmt.dateOnly.string(from: meeting.startedAt)
        guard let what, !what.isEmpty else { return "Updated after “\(meeting.title)” (\(stamp))." }
        return "After “\(meeting.title)” (\(stamp)): \(what)"
    }

    /// Re-derive a project's learned note from its most recent summarized meeting, on request.
    func refreshProjectContext(_ projectID: UUID) {
        guard !updatingContext.contains(projectID) else { return }
        if let hub, settings.mode == .hub, hub.isEnabled {
            updatingContext.insert(projectID)
            Task {
                defer { self.updatingContext.remove(projectID) }
                do { try await hub.refreshProjectContext(projectID) }
                catch { Log.pipeline.warning("project context refresh failed: \(error.localizedDescription)") }
            }
            return
        }
        guard let meeting = store.meetings(in: projectID).first(where: { store.summaryMarkdown(for: $0) != nil }),
              let markdown = store.summaryMarkdown(for: meeting) else { return }
        Task {
            do {
                let summarizer = try self.makeSummarizer()
                await self.updateProjectContext(for: meeting, summarizer: summarizer, summaryMarkdown: markdown)
            } catch {
                Log.pipeline.warning("project context refresh failed: \(error.localizedDescription)")
            }
            self.setProgress(meeting.id, nil)
        }
    }

    // MARK: - Action item advice

    func isAdvising(_ itemID: UUID) -> Bool { advising.contains(itemID) }

    /// "How would you handle this?" for one action item — only ever on the user's say-so.
    func requestGuidance(for item: ActionItem, in meeting: Meeting) {
        guard !advising.contains(item.id) else { return }
        advising.insert(item.id)
        adviceErrors[item.id] = nil
        Task {
            defer { self.advising.remove(item.id) }
            do {
                let text = try await self.guidance(for: item, in: meeting)
                guard var fresh = self.store.meeting(meeting.id),
                      let i = fresh.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
                fresh.actionItems[i].guidance = text
                fresh.actionItems[i].guidanceAt = Date()
                self.store.update(fresh)
            } catch {
                self.adviceErrors[item.id] = error.localizedDescription
            }
        }
    }

    private func guidance(for item: ActionItem, in meeting: Meeting) async throws -> String {
        if let hub, settings.mode == .hub, hub.isEnabled {
            return try await hub.advise(item: item.id, in: meeting.id)
        }
        let contexts = store.contexts(meeting.projectID)
        let request = AdviceRequest(
            item: item, meeting: meeting, projectName: store.project(meeting.projectID)?.name ?? "(none)",
            userContext: contexts.user, learnedContext: contexts.learned,
            summaryMarkdown: store.summaryMarkdown(for: meeting) ?? "(no summary was written for this meeting)",
            otherOpenItems: store.openProjectItems(for: meeting), userName: settings.userName,
            debugDirectory: store.folder(for: meeting))
        return try await makeSummarizer().advise(request)
    }

    /// The locally configured provider. In hub mode the hub holds the settings, so callers route there instead.
    private func makeSummarizer() throws -> any Summarizer {
        try SummarizerFactory.make(settings.summarizerSettings)
    }
}
