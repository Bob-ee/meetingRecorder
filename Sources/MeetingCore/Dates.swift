import Foundation

/// The date strings the summarizer hands back, and how they become `EventDate`s.
///
/// The model is told the meeting's date and zone and asked for local strings — `2026-09-04` for a day,
/// `2026-09-04T15:00` when a time was said — because models are reliable at that and unreliable at UTC offsets.
/// Whichever machine renders the prompt also parses the reply, so both see the same zone.
public enum LocalDate {
    /// Accepts `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM[:SS]` (a space instead of the `T` works), and full ISO-8601 with a
    /// zone. Zone-less values are read in `zone`.
    public static func parse(_ raw: String?, in zone: TimeZone = .current) -> EventDate? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if ["null", "none", "tbd", "unknown"].contains(s.lowercased()) { return nil }
        s = s.replacingOccurrences(of: " ", with: "T")

        if s.count > 10, s.hasSuffix("Z") || s.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            var d = iso.date(from: s)
            if d == nil { iso.formatOptions.insert(.withFractionalSeconds); d = iso.date(from: s) }
            if let d { return EventDate(date: d, hasTime: true, timeZone: zone) }
        }

        let parts = s.split(separator: "T", maxSplits: 1).map(String.init)
        let ymd = parts[0].split(separator: "-").map { Int($0) }
        guard ymd.count == 3, let y = ymd[0], let m = ymd[1], let d = ymd[2],
              (1900...2200).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        var comps = DateComponents(year: y, month: m, day: d)
        var hasTime = false
        if parts.count == 2 {
            let hm = parts[1].split(separator: ":").map { Int($0.prefix(2)) }
            if hm.count >= 2, let h = hm[0], let min = hm[1], (0...23).contains(h), (0...59).contains(min) {
                comps.hour = h; comps.minute = min; hasTime = true
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard let date = cal.date(from: comps) else { return nil }
        return EventDate(date: date, hasTime: hasTime, timeZone: zone)
    }

    /// The business-hours conventions the prompt also spells out, for when the model names the part of the day in
    /// `due` ("end of day Friday") but hands back a date-only `due_date` anyway.
    public static func impliedTime(in text: String?) -> (hour: Int, minute: Int)? {
        guard let t = text?.lowercased() else { return nil }
        let table: [([String], (Int, Int))] = [
            (["end of business", "end of day", "end of the day", "eod", "cob", "close of business", "by end"], (17, 0)),
            (["first thing", "start of day", "start of the day"], (9, 0)),
            (["noon", "lunch", "midday"], (12, 0)),
            (["morning"], (10, 0)),
            (["afternoon"], (14, 0)),
            (["evening", "tonight"], (18, 0)),
        ]
        for (words, time) in table where words.contains(where: { word in
            // Whole-word match so "eod" doesn't fire inside "geodesic".
            t.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
        }) { return time }
        return nil
    }

    /// Between the start of the meeting's day and three years out; anything else is a model slip, not a date.
    static func plausible(_ d: EventDate, for meeting: Meeting, in zone: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let dayStart = cal.startOfDay(for: meeting.startedAt)
        return d.date >= dayStart && d.date <= meeting.startedAt.addingTimeInterval(3 * 366 * 86_400)
    }
}

extension MeetingSummary {
    /// The model's action items as `ActionItem`s, deadlines resolved against the meeting's date.
    public func resolvedActionItems(for meeting: Meeting, in zone: TimeZone = .current) -> [ActionItem] {
        actionItems.compactMap { item in
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            var due = LocalDate.parse(item.dueDate, in: zone)
            if let d = due, !d.hasTime, let (hour, minute) = LocalDate.impliedTime(in: item.due) {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone
                if let at = cal.date(bySettingHour: hour, minute: minute, second: 0, of: d.date) {
                    due = EventDate(date: at, hasTime: true, timeZone: zone)
                }
            }
            if let d = due, !LocalDate.plausible(d, for: meeting, in: zone) { due = nil }
            return ActionItem(task: task, owner: Self.clean(item.owner), due: Self.clean(item.due), dueDate: due)
        }
    }

    /// The model's events as `MeetingEvent`s. Drops ones without a usable date, and duplicates.
    public func resolvedEvents(for meeting: Meeting, in zone: TimeZone = .current) -> [MeetingEvent] {
        var seen: Set<String> = []
        return events.compactMap { e in
            let title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, var start = LocalDate.parse(e.start, in: zone) else { return nil }
            if e.allDay, start.hasTime {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone
                start = EventDate(date: cal.startOfDay(for: start.date), hasTime: false, timeZone: zone)
            }
            guard LocalDate.plausible(start, for: meeting, in: zone) else { return nil }
            let key = "\(title.lowercased())|\(start.date.timeIntervalSince1970)"
            guard seen.insert(key).inserted else { return nil }
            var end: Date?
            if start.hasTime, let parsed = LocalDate.parse(e.end, in: zone), parsed.hasTime,
               parsed.date > start.date, parsed.date.timeIntervalSince(start.date) <= 86_400 {
                end = parsed.date
            }
            return MeetingEvent(title: title, start: start, end: end, location: Self.clean(e.location), context: Self.clean(e.context))
        }
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.lowercased() != "null" else { return nil }
        return t
    }
}
