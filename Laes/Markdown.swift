import SwiftUI

/// Formats a note written in Markdown: inline styles and links, plus headings, bullets and checkboxes
/// line by line. shortcut: no tables, quotes or code blocks (shown as typed); use a full parser if notes need them.
func renderMarkdown(_ text: String) -> AttributedString {
    var out = AttributedString()
    for (index, line) in text.components(separatedBy: "\n").enumerated() {
        if index > 0 { out += AttributedString("\n") }
        let trimmed = line.drop { $0 == " " }
        let indent = String(repeating: " ", count: line.count - trimmed.count)
        var prefix = indent, body = String(trimmed), isHeading = false
        let hashes = trimmed.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") {
            isHeading = true
            body = String(trimmed.dropFirst(hashes + 1))
        } else if let box = ["- [ ] ": "☐ ", "- [x] ": "☑ ", "- [X] ": "☑ "].first(where: { trimmed.hasPrefix($0.key) }) {
            prefix += box.value
            body = String(trimmed.dropFirst(6))
        } else if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) {
            prefix += "• "
            body = String(trimmed.dropFirst(2))
        }
        var part = inlineMarkdown(body)
        if isHeading { part.font = hashes == 1 ? .title2.bold() : hashes == 2 ? .title3.bold() : .headline }
        out += AttributedString(prefix) + part
    }
    return out
}

/// Inline styles. Markdown has no underline, so notes use <u>…</u> for it.
private func inlineMarkdown(_ text: String) -> AttributedString {
    func parse(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    var out = AttributedString()
    for (index, piece) in text.components(separatedBy: "<u>").enumerated() {
        guard index > 0, let end = piece.range(of: "</u>") else {
            out += parse((index > 0 ? "<u>" : "") + piece)
            continue
        }
        var underlined = parse(String(piece[..<end.lowerBound]))
        underlined.underlineStyle = .single
        out += underlined + parse(String(piece[end.upperBound...]))
    }
    return out
}
