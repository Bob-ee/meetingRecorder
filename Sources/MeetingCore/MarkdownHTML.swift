import Foundation

/// Minimal Markdown → HTML for clipboard use. Inline styles only (Gmail strips <style> blocks),
/// checkboxes as ☐/☑ glyphs (form controls get dropped by mail clients).
public enum MarkdownHTML {
    public static func render(_ markdown: String) -> String {
        var html = ""
        var openListTag: String?          // "ul", "ol", or "check"
        var paragraph: [String] = []

        func closeList() {
            if let tag = openListTag {
                html += (tag == "ol" ? "</ol>\n" : "</ul>\n")
                openListTag = nil
            }
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html += "<p style=\"margin:0 0 10px\">\(inline(paragraph.joined(separator: " ")))</p>\n"
            paragraph = []
        }
        func openList(_ tag: String) {
            guard openListTag != tag else { return }
            closeList()
            switch tag {
            case "ol": html += "<ol style=\"margin:0 0 10px;padding-left:24px\">\n"
            case "check": html += "<ul style=\"list-style:none;margin:0 0 10px;padding-left:6px\">\n"
            default: html += "<ul style=\"margin:0 0 10px;padding-left:24px\">\n"
            }
            openListTag = tag
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); closeList(); continue }

            if line.hasPrefix("#") {
                flushParagraph(); closeList()
                let level = min(line.prefix { $0 == "#" }.count, 4)
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                let size = ["22px", "18px", "15px", "14px"][level - 1]
                html += "<h\(level) style=\"font-size:\(size);font-weight:600;margin:\(level == 1 ? "0" : "16px") 0 6px\">\(inline(text))</h\(level)>\n"
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                flushParagraph(); openList("check")
                let checked = !line.hasPrefix("- [ ] ")
                html += "<li style=\"margin:0 0 4px\">\(checked ? "☑" : "☐")&nbsp; \(inline(String(line.dropFirst(6))))</li>\n"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph(); openList("ul")
                html += "<li style=\"margin:0 0 4px\">\(inline(String(line.dropFirst(2))))</li>\n"
            } else if let m = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph(); openList("ol")
                html += "<li style=\"margin:0 0 4px\">\(inline(String(line[m.upperBound...])))</li>\n"
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        flushParagraph(); closeList()

        return "<div style=\"font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:14px;line-height:1.45;color:#1d1d1f\">\n\(html)</div>"
    }

    public static func inline(_ text: String) -> String {
        var s = escape(text)
        s = replace(s, #"`([^`]+)`"#,
                    "<code style=\"font-family:Menlo,Monaco,monospace;font-size:13px;background:#f2f2f4;padding:1px 4px;border-radius:3px\">$1</code>")
        s = replace(s, #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, "<a href=\"$2\">$1</a>")
        s = replace(s, #"\*\*(.+?)\*\*"#, "<b>$1</b>")
        s = replace(s, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "<i>$1</i>")
        s = replace(s, #"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#, "<i>$1</i>")
        return s
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
