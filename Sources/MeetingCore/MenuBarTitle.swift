import Foundation

/// Text for the menu bar's "next meeting" label: a calendar title cut down to fit, and how long until it starts.
/// Pure functions, so the rules are testable without a calendar.
public enum MenuBarTitle {
    /// Longest title the menu bar gets. The countdown comes on top of this.
    public static let maxLength = 22

    /// A quick, offline shortening — what shows until (or instead of) the model's version.
    /// Drops invitation boilerplate, bracketed tags and trailing dates, then cuts at a word boundary.
    public static func heuristic(_ title: String, maxLength: Int = maxLength) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // "Invitation: X @ Tue Oct 7…", "Updated invitation with note: X", "FW: X", "RE: X"
        let prefixes = ["updated invitation with note:", "updated invitation:", "invitation:", "accepted:",
                        "fwd:", "fw:", "re:"]
        var stripped = true
        while stripped {
            stripped = false
            for p in prefixes where t.lowercased().hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        if let at = t.range(of: " @ ") { t = String(t[..<at.lowerBound]) }

        // [EXTERNAL], (Recurring), {tags}
        t = t.replacingOccurrences(of: #"\s*[\[\(\{][^\]\)\}]*[\]\)\}]\s*"#, with: " ", options: .regularExpression)
        // Trailing dates: "- 10/14", "– Oct 14", "2026-10-14"
        t = t.replacingOccurrences(
            of: #"\s*[-–—|:]?\s*(\d{1,4}[/.-]\d{1,2}([/.-]\d{1,4})?|(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(,?\s*\d{4})?)\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|:·,"))
        if t.isEmpty { t = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        return truncate(t, to: maxLength)
    }

    /// Cut to `length` characters at a word boundary when one is close, with an ellipsis.
    public static func truncate(_ s: String, to length: Int = maxLength) -> String {
        guard s.count > length, length > 1 else { return s }
        let hard = String(s.prefix(length - 1))
        if let space = hard.lastIndex(of: " "), hard.distance(from: hard.startIndex, to: space) >= length / 2 {
            return hard[..<space].trimmingCharacters(in: CharacterSet(charactersIn: " -–—|:·,")) + "…"
        }
        return hard.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "now", "in 5m", "in 1h", "in 1h 20m". `start` is when the meeting begins.
    public static func countdown(to start: Date, from now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 30 { return "now" }
        // Round up: at 4m10s away the meeting is "in 5m", never "in 4m" with it starting before the label changes.
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h)h" : "in \(h)h \(m)m"
    }

    // MARK: - Model shortening

    public static let shortenSystem = """
        You write labels for a Mac menu bar, where there is room for about \(maxLength) characters. \
        Given calendar event titles, return a short label for each that the owner of the calendar would \
        recognise at a glance.
        Rules:
        - At most \(maxLength) characters each. Shorter is better if it stays recognisable.
        - Keep the part that tells this meeting apart from others: the person, team, customer or topic.
        - Drop boilerplate: "Invitation:", "Meeting", "Call", "Sync" when something more specific remains, \
        company names everyone shares, dates, times, time zones, recurrence notes, meeting-link text, emoji.
        - Use common abbreviations where natural: 1:1, Eng, PM, Q3, w/, mtg, Rev.
        - Never invent words that aren't implied by the title. Keep names spelled as given.
        - Return exactly one label per title, in the same order.
        """

    public static let shortenSchema = """
        {"type":"object","properties":{"labels":{"type":"array","items":{"type":"string"}}},"required":["labels"],"additionalProperties":false}
        """

    public static let shortenInstruction = "Shorten each calendar title on stdin (one per line, numbered). Reply with JSON {\"labels\": [...]}."

    public static func shortenUser(_ titles: [String]) -> String {
        titles.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    public struct Labels: Decodable { public var labels: [String] }
}
