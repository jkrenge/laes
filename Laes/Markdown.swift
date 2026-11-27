import SwiftUI

/// One line of a note: how far it is indented, what starts it, and the text after that.
struct MarkdownLine: Equatable {
    enum Kind: Equatable { case text, heading(Int), bullet, number(String), task(done: Bool) }
    var indent: Int
    var kind: Kind
    var body: String

    init(_ line: String) {
        let trimmed = line.drop { $0 == " " }
        indent = line.count - trimmed.count
        let hashes = trimmed.prefix { $0 == "#" }.count
        let digits = trimmed.prefix { $0.isNumber }
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") {
            (kind, body) = (.heading(hashes), String(trimmed.dropFirst(hashes + 1)))
        } else if let box = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] ", "+ [ ] ", "+ [x] ", "+ [X] "].first(where: { trimmed.hasPrefix($0) }) {
            (kind, body) = (.task(done: box.contains("[ ]") == false), String(trimmed.dropFirst(6)))
        } else if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) {
            (kind, body) = (.bullet, String(trimmed.dropFirst(2)))
        } else if !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") {
            (kind, body) = (.number(String(digits)), String(trimmed.dropFirst(digits.count + 2)))
        } else {
            (kind, body) = (.text, String(trimmed))
        }
    }
}

/// Formats a note written in Markdown: inline styles and links, plus headings, bullets and checkboxes
/// line by line. shortcut: no tables, quotes or code blocks (shown as typed); use a full parser if notes need them.
func renderMarkdown(_ text: String) -> AttributedString {
    var out = AttributedString()
    for (index, raw) in text.components(separatedBy: "\n").enumerated() {
        if index > 0 { out += AttributedString("\n") }
        let line = MarkdownLine(raw)
        var prefix = String(repeating: " ", count: line.indent)
        switch line.kind {
        case .task(let done): prefix += done ? "☑ " : "☐ "
        case .bullet: prefix += "• "
        case .number(let n): prefix += n + ". "
        case .text, .heading: break
        }
        var part = inlineMarkdown(line.body)
        if case .heading(let level) = line.kind { part.font = level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline }
        out += AttributedString(prefix) + part
    }
    return out
}

/// A line as it reads, without its Markdown: "- [ ] **Call** [Ana](…)" is "Call Ana".
func plainMarkdown(_ line: String) -> String {
    String(inlineMarkdown(MarkdownLine(line).body).characters).trimmingCharacters(in: .whitespaces)
}

/// The note text with the to-do on this line ticked, or unticked.
func toggleTask(in text: String, line index: Int) -> String {
    var lines = text.components(separatedBy: "\n")
    guard lines.indices.contains(index), case .task(let done) = MarkdownLine(lines[index]).kind,
          let box = lines[index].range(of: done ? "[x]" : "[ ]", options: done ? .caseInsensitive : []) else { return text }
    lines[index].replaceSubrange(box, with: done ? "[ ]" : "[x]")
    return lines.joined(separator: "\n")
}

/// Inline styles. Markdown has no underline, so notes use <u>…</u> for it.
func inlineMarkdown(_ text: String) -> AttributedString {
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

#if os(iOS)
/// A note for reading on iPhone and iPad, a row per line: a list item's wrapped lines start under its text,
/// and a to-do's box can be tapped.
struct MarkdownReader: View {
    let text: String
    var onToggle: ((Int) -> Void)?   // the line of the to-do tapped

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, raw in
                row(index, MarkdownLine(raw))
            }
        }
    }

    @ViewBuilder private func row(_ index: Int, _ line: MarkdownLine) -> some View {
        switch line.kind {
        case .heading(let level):
            Text(inlineMarkdown(line.body)).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .text:
            Text(line.body.isEmpty ? AttributedString(" ") : inlineMarkdown(line.body))
        case .bullet, .number, .task:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                marker(index, line.kind)
                if case .task(true) = line.kind {
                    Text(inlineMarkdown(line.body)).strikethrough().foregroundStyle(.secondary)
                } else {
                    Text(inlineMarkdown(line.body))
                }
            }
            .padding(.leading, CGFloat(line.indent) * 8)
        }
    }

    @ViewBuilder private func marker(_ index: Int, _ kind: MarkdownLine.Kind) -> some View {
        switch kind {
        case .task(let done):
            Button { onToggle?(index) } label: {
                Text(Image(systemName: done ? "checkmark.square" : "square")).foregroundStyle(Color.brandText)
                    .contentShape(Rectangle().inset(by: -10))   // an easier target than the box alone
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Done" : "Not done")
            .accessibilityHint(done ? "Marks the to-do as not done" : "Marks the to-do as done")
        case .number(let n): Text(n + ".").monospacedDigit().foregroundStyle(Color.brandText)
        default: Text("•").foregroundStyle(Color.brandText)
        }
    }
}
#endif
