import Fluent
import Foundation
import MeetingCore
import MeetingEngine
import Vapor

func settingsRoutes(_ r: RoutesBuilder) {
    r.get("settings") { req -> HubSettings in
        let p = try req.principal
        var s = try await SettingsStore.load(workspaceID: p.workspaceID, db: req.db, secrets: req.application.secrets)
        s.summarizer = s.summarizer.redacted()
        return s
    }

    r.put("settings") { req -> HubSettings in
        let p = try req.principal
        let incoming = try req.content.decode(HubSettings.self)
        let stored = try await SettingsStore.load(workspaceID: p.workspaceID, db: req.db, secrets: req.application.secrets)
        var merged = incoming
        merged.summarizer = stored.summarizer.merging(update: incoming.summarizer)
        if merged.summarizer.model.trimmingCharacters(in: .whitespaces).isEmpty {
            merged.summarizer.model = merged.summarizer.provider.defaultModel
        }
        try await SettingsStore.save(merged, workspaceID: p.workspaceID, db: req.db, secrets: req.application.secrets)
        req.application.eventBus.post(HubEvent(kind: .settingsUpdated))
        merged.summarizer = merged.summarizer.redacted()
        return merged
    }

    /// Runs the summarizer on a tiny transcript. Body (optional): settings to test before saving them.
    r.post("settings", "test") { req -> TestResult in
        let p = try req.principal
        let stored = try await SettingsStore.load(workspaceID: p.workspaceID, db: req.db, secrets: req.application.secrets)
        var settings = stored
        if let incoming = try? req.content.decode(HubSettings.self) {
            settings = incoming
            settings.summarizer = stored.summarizer.merging(update: incoming.summarizer)
        }
        let started = Date()
        do {
            let summarizer = try SummarizerFactory.make(settings.summarizer)
            let meeting = Meeting(projectID: UUID(), title: "Connection test", startedAt: Date(), durationSeconds: 45, status: .transcribed)
            let transcript = """
            **[00:00:01] \(settings.userName):** Quick check that the summarizer works. Let's ship the hub on Friday.

            **[00:00:09] Speaker 1:** Sounds good. I'll write the release notes tomorrow.
            """
            let summary = try await summarizer.summarize(SummaryRequest(
                transcriptMarkdown: transcript, projectName: "Test", projectContext: "", meeting: meeting, userName: settings.userName))
            let elapsed = Date().timeIntervalSince(started)
            return TestResult(ok: true, message: "\(summarizer.displayName) replied in \(String(format: "%.1f", elapsed))s: “\(summary.title ?? "ok")”",
                              elapsedSeconds: elapsed)
        } catch {
            return TestResult(ok: false, message: error.localizedDescription, elapsedSeconds: Date().timeIntervalSince(started))
        }
    }
}
