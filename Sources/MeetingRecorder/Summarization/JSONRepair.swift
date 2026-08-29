import Foundation

/// Makes "almost JSON" from a language model parseable: strips code fences and leading/trailing prose,
/// escapes raw control characters inside strings, and removes trailing commas.
enum JSONRepair {
    static func repair(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = s.range(of: "```json") ?? s.range(of: "```") {
            s = String(s[fence.upperBound...])
            if let close = s.range(of: "```", options: .backwards) { s = String(s[..<close.lowerBound]) }
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return s }
        s = String(s[start...end])

        var out = ""
        out.reserveCapacity(s.utf16.count + 64)
        var inString = false
        var escaped = false
        var pendingComma = false   // a ',' seen outside a string, not yet emitted

        for ch in s {
            if inString {
                if escaped {
                    out.append(ch); escaped = false
                } else if ch == "\\" {
                    out.append(ch); escaped = true
                } else if ch == "\"" {
                    out.append(ch); inString = false
                } else if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, scalar.value < 0x20 {
                    switch ch {
                    case "\n": out += "\\n"
                    case "\r": out += "\\r"
                    case "\t": out += "\\t"
                    default: out += String(format: "\\u%04x", scalar.value)
                    }
                } else {
                    out.append(ch)
                }
                continue
            }
            // outside a string
            if ch == "," { pendingComma = true; continue }
            if ch.isWhitespace { if pendingComma { out.append(" ") } else { out.append(ch) }; continue }
            if pendingComma {
                if ch != "}" && ch != "]" { out.append(",") }   // drop trailing commas
                pendingComma = false
            }
            out.append(ch)
            if ch == "\"" { inString = true; escaped = false }
        }
        return out
    }
}
