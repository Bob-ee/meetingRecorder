import SwiftUI

/// Small block-level Markdown renderer: headings, bullets, numbered lists, checkboxes, paragraphs.
/// Inline formatting is handled by AttributedString(markdown:).
struct MarkdownView: View {
    let markdown: String

    private enum Block {
        case heading(Int, String)
        case bullet(String, checked: Bool?)
        case numbered(Int, String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                flush()
                let checked = !line.hasPrefix("- [ ] ")
                out.append(.bullet(String(line.dropFirst(6)), checked: checked))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2)), checked: nil))
            } else if let m = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush()
                let n = Int(line[m].filter { $0.isNumber }) ?? 0
                out.append(.numbered(n, String(line[m.upperBound...])))
            } else {
                para.append(line)
            }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text)
                        .font(level == 1 ? .title.weight(.bold) : level == 2 ? .title2.weight(.semibold) : .headline)
                        .padding(.top, level == 1 ? 4 : 10)
                case .bullet(let text, let checked):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let checked {
                            Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
                        } else {
                            Text("•").foregroundStyle(.secondary)
                        }
                        inline(text)
                    }
                    .padding(.leading, 6)
                case .numbered(let n, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        inline(text)
                    }
                    .padding(.leading, 6)
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
