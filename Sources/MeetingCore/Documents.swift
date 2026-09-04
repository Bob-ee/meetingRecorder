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

    public static let actionItemsHeading = "Action items"
    public static let upcomingHeading = "Upcoming"

    /// Action items as a Markdown checklist, checked state included.
    public static func actionItemsMarkdown(_ items: [ActionItem]) -> String {
        items.map { item in
            var line = item.done ? "- [x] " : "- [ ] "
            if let owner = item.owner, !owner.isEmpty { line += "**\(owner)** — " }
            line += item.task
            // Files outlive the year, so the resolved day is written in full here (the UI's chip drops it).
            if let d = item.dueDate { line += " _(due \(Fmt.when(d, end: nil)))_" }
            else if let due = item.due, !due.isEmpty { line += " _(due \(due))_" }
            return line
        }.joined(separator: "\n")
    }

    /// Suggested events as a list: "- **Design review** — Thu, Sep 4, 2026 at 3:00 PM – 4:00 PM, Room 2 — what was said".
    public static func eventsMarkdown(_ events: [MeetingEvent]) -> String {
        events.map { e in
            var line = "- **\(e.title)** — \(Fmt.when(e.start, end: e.end))"
            if let location = e.location, !location.isEmpty { line += ", \(location)" }
            if let context = e.context, !context.isEmpty { line += " — \(context)" }
            return line
        }.joined(separator: "\n")
    }

    /// The saved summary with its "Action items" and "Upcoming" sections swapped for the live lists
    /// (done states, manual additions, dismissed events).
    public static func summaryExport(summaryMarkdown md: String, actionItems: [ActionItem], events: [MeetingEvent] = []) -> String {
        let items = actionItemsMarkdown(actionItems)
        var out = replacingSection(in: md, titled: actionItemsHeading, with: items.isEmpty ? "_None_" : items,
                                   appendIfMissing: !items.isEmpty)
        let upcoming = eventsMarkdown(events.filter { !$0.dismissed })
        out = replacingSection(in: out, titled: upcomingHeading, with: upcoming.isEmpty ? nil : upcoming,
                               appendIfMissing: !upcoming.isEmpty)
        return out
    }

    /// The document without one of its `## ` sections (heading included).
    public static func removingSection(_ md: String, titled heading: String) -> String {
        replacingSection(in: md, titled: heading, with: nil, appendIfMissing: false)
    }

    /// Replace the body of the `## heading` section (up to the next `## `) with `body`; nil removes the section.
    static func replacingSection(in md: String, titled heading: String, with body: String?, appendIfMissing: Bool) -> String {
        let marker = "## \(heading)".lowercased()
        let lines = md.components(separatedBy: "\n")
        var out: [String] = []
        var replaced = false
        var i = 0
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(marker) {
                if let body { out += ["## \(heading)", "", body, ""] }
                i += 1
                while i < lines.count, !lines[i].hasPrefix("## ") { i += 1 }
                replaced = true
                continue
            }
            out.append(lines[i])
            i += 1
        }
        if !replaced, appendIfMissing, let body { out += ["", "## \(heading)", "", body, ""] }
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
            out += summaryExport(summaryMarkdown: summaryMarkdown, actionItems: meeting.actionItems, events: meeting.events)
                .trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        } else {
            if !meeting.actionItems.isEmpty {
                out += "## \(actionItemsHeading)\n\n" + actionItemsMarkdown(meeting.actionItems) + "\n\n"
            }
            let upcoming = meeting.upcomingEvents
            if !upcoming.isEmpty { out += "## \(upcomingHeading)\n\n" + eventsMarkdown(upcoming) + "\n\n" }
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
    /// Merge a fresh list (a new summary, or the hub's copy) into the existing one: completion state of unchanged
    /// tasks is kept, owners/dues are refreshed, items the user added by hand survive. "In calendar" is kept only
    /// while the deadline stays on the same day.
    public static func merge(existing: [ActionItem], fresh: [ActionItem]) -> [ActionItem] {
        var merged: [ActionItem] = fresh.filter { !$0.task.isEmpty }.map { item in
            guard let old = existing.first(where: { $0.task.caseInsensitiveCompare(item.task) == .orderedSame }) else { return item }
            var kept = old
            kept.owner = item.owner
            kept.due = item.due
            kept.dueDate = item.dueDate
            // Advice the user asked for stays; the quote is only filled in when we didn't already have one.
            if kept.sourceQuote == nil { kept.sourceQuote = item.sourceQuote }
            if old.dueDate?.date == item.dueDate?.date {
                kept.calendarAddedAt = old.calendarAddedAt ?? item.calendarAddedAt
            } else {
                kept.calendarAddedAt = item.calendarAddedAt
            }
            return kept
        }
        merged += existing.filter { old in
            old.isManual && !merged.contains { $0.task.caseInsensitiveCompare(old.task) == .orderedSame }
        }
        return merged
    }
}

public enum MeetingEvents {
    /// Merge a fresh list of suggested events into the existing one, keeping what the user did with them
    /// (added to calendar, dismissed) when the event is recognizably the same: same title, or same moment.
    public static func merge(existing: [MeetingEvent], fresh: [MeetingEvent]) -> [MeetingEvent] {
        fresh.map { event in
            let old = existing.first { $0.title.caseInsensitiveCompare(event.title) == .orderedSame }
                ?? existing.first { $0.start.hasTime && event.start.hasTime && $0.start.date == event.start.date }
            guard let old else { return event }
            var kept = event
            kept.id = old.id
            kept.addedAt = old.addedAt ?? event.addedAt
            kept.dismissed = old.dismissed || event.dismissed
            return kept
        }
    }
}

// MARK: - Carrying items between meetings

public extension ActionItems {
    /// One of a project's earlier items, changed by a later meeting and needing to be written back.
    struct CarriedItem: Sendable {
        public var meetingID: UUID
        public var item: ActionItem
        public init(meetingID: UUID, item: ActionItem) { self.meetingID = meetingID; self.item = item }
    }

    struct CarryForwardResult: Sendable {
        /// Items belonging to earlier meetings: closed out, or restated with a new owner or deadline.
        public var edits: [CarriedItem]
        /// This meeting's own action items, with restatements of earlier ones taken out.
        public var items: [ActionItem]
    }

    /// The project's still-open items, numbered for the prompt. `meetingID` — the meeting being summarized — is
    /// left out, since its own items are being rewritten. When there are more than `limit`, the most recent win,
    /// but they are always presented oldest first so the refs read in the order things happened.
    static func openProjectItems(in meetings: [Meeting], excluding meetingID: UUID, limit: Int = 40) -> [OpenProjectItem] {
        // Walk newest first so a cap keeps the most recent items, then put them back in the order things
        // happened — including within a meeting, so the refs read the way the list does.
        var collected: [(item: ActionItem, meeting: Meeting, position: Int)] = []
        for meeting in meetings.filter({ $0.id != meetingID }).sorted(by: { $0.startedAt > $1.startedAt }) {
            for (position, item) in meeting.openActionItems.enumerated()
            where !item.task.trimmingCharacters(in: .whitespaces).isEmpty {
                collected.append((item, meeting, position))
                if collected.count >= limit { break }
            }
            if collected.count >= limit { break }
        }
        collected.sort {
            $0.meeting.startedAt == $1.meeting.startedAt ? $0.position < $1.position
                                                         : $0.meeting.startedAt < $1.meeting.startedAt
        }
        return collected.enumerated().map { i, pair in
            OpenProjectItem(ref: "P\(i + 1)", id: pair.item.id, meetingID: pair.meeting.id, task: pair.item.task,
                            owner: pair.item.owner, dueLabel: pair.item.dueLabel, raisedAt: pair.meeting.startedAt,
                            meetingTitle: pair.meeting.title)
        }
    }

    /// Apply what a summary said about items already open elsewhere in the project: close the ones this meeting
    /// finished, and fold restatements into the item they restate rather than raising a near-duplicate.
    static func carryForward(pairs: [(item: ActionItem, duplicateOf: String?)],
                             completed: [MeetingSummary.Completion],
                             openItems: [OpenProjectItem],
                             itemsByID: [UUID: ActionItem],
                             meetingID: UUID) -> CarryForwardResult {
        func normalized(_ ref: String?) -> String? {
            let r = ref?.trimmingCharacters(in: .whitespaces).uppercased()
            return (r?.isEmpty ?? true) ? nil : r
        }
        let byRef = Dictionary(openItems.map { ($0.ref.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        // Keyed by item id so an item named twice in one reply is only written back once.
        var edited: [UUID: CarriedItem] = [:]
        var closed: Set<UUID> = []

        for completion in completed {
            guard let ref = normalized(completion.ref), let open = byRef[ref],
                  var item = itemsByID[open.id], !item.done else { continue }
            item.done = true
            item.lastDiscussedMeetingID = meetingID
            edited[open.id] = CarriedItem(meetingID: open.meetingID, item: item)
            closed.insert(open.id)
        }

        var keep: [ActionItem] = []
        for (fresh, duplicateOf) in pairs {
            // No ref, an unknown ref, or one this meeting also closed: treat it as this meeting's own item.
            guard let ref = normalized(duplicateOf), let open = byRef[ref], !closed.contains(open.id),
                  var item = edited[open.id]?.item ?? itemsByID[open.id] else {
                keep.append(fresh)
                continue
            }
            if let owner = fresh.owner, !owner.isEmpty { item.owner = owner }
            if fresh.dueDate != nil || fresh.due != nil {
                item.due = fresh.due
                // Only drop "in calendar" when the day itself moved.
                if item.dueDate?.date != fresh.dueDate?.date { item.calendarAddedAt = nil }
                item.dueDate = fresh.dueDate
            }
            if item.sourceQuote == nil { item.sourceQuote = fresh.sourceQuote }
            item.lastDiscussedMeetingID = meetingID
            edited[open.id] = CarriedItem(meetingID: open.meetingID, item: item)
        }
        return CarryForwardResult(edits: Array(edited.values), items: keep)
    }
}
