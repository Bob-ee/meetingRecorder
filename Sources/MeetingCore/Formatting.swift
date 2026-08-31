import Foundation

public enum Fmt {
    public static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    public static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    public static let folderStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    public enum WhenStyle { case short, long }

    /// A resolved date for people: "Thu, Sep 4, 2026 at 3:00 PM – 4:00 PM", or "Thu, Sep 4, 2026" for a whole day.
    /// `.short` drops the year when it's this year: "Thu, Sep 4, 3:00 PM". Times are shown in the viewer's zone;
    /// whole days stay on the day they were resolved to.
    public static func when(_ d: EventDate, end: Date?, style: WhenStyle = .long) -> String {
        let zone = d.hasTime ? TimeZone.current : d.tz
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let thisYear = cal.component(.year, from: d.date) == cal.component(.year, from: Date())
        let day = DateFormatter()
        day.timeZone = zone
        day.setLocalizedDateFormatFromTemplate(style == .short && thisYear ? "EEE MMM d" : "EEE MMM d yyyy")
        var out = day.string(from: d.date)
        guard d.hasTime else { return out }
        let time = DateFormatter()
        time.timeZone = zone
        time.timeStyle = .short
        time.dateStyle = .none
        out += (style == .short ? ", " : " at ") + time.string(from: d.date)
        if let end, end > d.date, style == .long {
            out += " – " + (cal.isDate(end, inSameDayAs: d.date) ? time.string(from: end) : "\(day.string(from: end)) \(time.string(from: end))")
        }
        return out
    }

    /// For the summarizer: "Thursday, August 28, 2026 at 4:30 PM (EDT)" — a weekday and a zone, so "Friday" and
    /// "3 PM" can be resolved.
    public static func promptDate(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("EEEE MMMM d yyyy")
        let t = DateFormatter()
        t.timeZone = zone
        t.timeStyle = .short
        t.dateStyle = .none
        let abbrev = zone.abbreviation(for: date) ?? zone.identifier
        return "\(f.string(from: date)) at \(t.string(from: date)) (\(abbrev), \(zone.identifier))"
    }

    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }

    public static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    public static func sanitizeFilename(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var s = name.components(separatedBy: bad).joined(separator: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 60 { s = String(s.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "Untitled" : s
    }
}

/// ISO-8601 dates, pretty + sorted so files diff cleanly. Same settings on every device and on the hub.
public let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
}()

public let jsonDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

/// Compact variant for the wire.
public let wireEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}()
