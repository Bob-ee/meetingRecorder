import Foundation

/// The Markdown documents derived from a meeting. Used identically by the app (files on disk, clipboard)
/// and by the hub (export mirror, API), so every device produces the same text.
public enum MeetingDocuments {
    public static func transcriptMarkdown(_ segments: [TranscriptSegment], meeting: Meeting) -> String {
        var out = "# Transcript — \(meeting.title)\n\n_\(Fmt.dateTime.string(from: meeting.startedAt))_\n\n"
        for s in segments {
            out += "**[\(Fmt.timestamp(s.start))] \(meeting.displayName(forSpeaker: s.speaker)):** \(s.text)\n\n"
        }
        return out
    }

    /// Action items as a Markdown checklist, checked state included.
    public static func actionItemsMarkdown(_ items: [ActionItem]) -> String {
        items.map { item in
            var line = item.done ? "- [x] " : "- [ ] "
            if let owner = item.owner, !owner.isEmpty { line += "**\(owner)** — " }
            line += item.task
            if let due = item.due, !due.isEmpty { line += " _(due \(due))_" }
            return line
        }.joined(separator: "\n")
    }

    /// The saved summary with its "Action items" section swapped for the live list (done states, manual additions).
    public static func summaryExport(summaryMarkdown md: String, actionItems: [ActionItem]) -> String {
        let items = actionItemsMarkdown(actionItems)
        let lines = md.components(separatedBy: "\n")
        var out: [String] = []
        var replaced = false
        var i = 0
        while i < lines.count {
            if lines[i].lowercased().hasPrefix("## action items") {
                out += ["## Action items", "", items.isEmpty ? "_None_" : items, ""]
                i += 1
                while i < lines.count, !lines[i].hasPrefix("## ") { i += 1 }
                replaced = true
                continue
            }
            out.append(lines[i])
            i += 1
        }
        if !replaced, !items.isEmpty { out += ["", "## Action items", "", items, ""] }
        return out.joined(separator: "\n")
    }

    /// One Markdown blob with everything — summary, notes and transcript — for pasting into Claude or an email.
    public static func everything(meeting: Meeting, projectName: String?, summaryMarkdown: String?,
                                  notes: String, transcript: [TranscriptSegment]) -> String {
        var out = "# \(meeting.title)\n\n"
        out += "- Date: \(Fmt.dateTime.string(from: meeting.startedAt))\n"
        out += "- Duration: \(Fmt.duration(meeting.durationSeconds))\n"
        if let projectName { out += "- Project: \(projectName)\n" }
        out += "\n"
        if let summaryMarkdown {
            out += summaryExport(summaryMarkdown: summaryMarkdown, actionItems: meeting.actionItems)
                .trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        } else if !meeting.actionItems.isEmpty {
            out += "## Action items\n\n" + actionItemsMarkdown(meeting.actionItems) + "\n\n"
        }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty { out += "## My notes\n\n\(trimmedNotes)\n\n" }
        if !transcript.isEmpty {
            out += "## Transcript\n\n"
            for s in transcript {
                out += "**[\(Fmt.timestamp(s.start))] \(meeting.displayName(forSpeaker: s.speaker)):** \(s.text)\n\n"
            }
        }
        return out
    }
}

public enum ActionItems {
    /// Merge a fresh summary's action items into the existing list: completion state of unchanged tasks is kept,
    /// owners/dues are refreshed, and items the user added by hand survive.
    public static func merge(existing: [ActionItem], fresh: [MeetingSummary.Item]) -> [ActionItem] {
        var merged: [ActionItem] = fresh.filter { !$0.task.isEmpty }.map { item in
            if let old = existing.first(where: { $0.task.caseInsensitiveCompare(item.task) == .orderedSame }) {
                var kept = old; kept.owner = item.owner; kept.due = item.due; return kept
            }
            return ActionItem(task: item.task, owner: item.owner, due: item.due)
        }
        merged += existing.filter { old in
            old.isManual && !merged.contains { $0.task.caseInsensitiveCompare(old.task) == .orderedSame }
        }
        return merged
    }
}
