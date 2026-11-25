import Foundation

/// A Markdown file in the app's OneDrive folder. The file name is its identity.
/// The title is the first line, a level-one heading. A linked calendar event lives in a front matter header,
/// so any tool that reads the file sees it:
///
///     ---
///     event: AAMkAG…            (Microsoft's id of that one occurrence)
///     event_title: Weekly check-in
///     event_start: 2026-11-23T09:00:00Z
///     event_categories: Private, Family     (so the note can be hidden with a private meeting)
///     ---
///
///     # Weekly check-in
struct Note: Identifiable, Hashable, Codable, Sendable {
    var name: String            // "2026-11-23 Weekly check-in.md"
    var text: String            // the whole file, header included
    var modified = Date.now
    var tag = ""                // OneDrive's version when last downloaded or uploaded; empty if never uploaded
    var isDirty = false         // changed here, not yet uploaded
    var id: String { name }
}

/// File name of a note that has no title yet.
let untitledNote = "Untitled"

typealias NoteMeta = [(key: String, value: String)]

extension Note {
    var parts: (meta: NoteMeta, body: String) { splitFrontMatter(text) }
    var body: String { parts.body }
    func meta(_ key: String) -> String? { parts.meta.first { $0.key == key }?.value }
    /// The "# Title" the note starts with, if it has one.
    var heading: String? {
        guard let first = body.components(separatedBy: "\n").first, first.hasPrefix("# ") else { return nil }
        let heading = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }
    /// Files written elsewhere may carry the title in the header, or only in their name.
    var title: String { heading ?? meta("title") ?? String(name.dropLast(name.hasSuffix(".md") ? 3 : 0)) }
    /// Nothing typed yet.
    var isBlank: Bool { body.trimmingCharacters(in: CharacterSet(charactersIn: "# \n")).isEmpty }
    var eventID: String? { meta("event") }
    var eventCategories: [String] { meta("event_categories")?.components(separatedBy: ", ") ?? [] }
    var eventStart: Date? { meta("event_start").flatMap { try? Date($0, strategy: .iso8601) } }

    mutating func update(title: String? = nil, body: String? = nil) {
        var (meta, text) = parts
        if let body { text = body }
        if let title {
            var lines = text.components(separatedBy: "\n")
            if lines[0].hasPrefix("# ") { lines[0] = "# " + title } else { lines.insert(contentsOf: ["# " + title, ""], at: 0) }
            text = lines.joined(separator: "\n")
            Self.set(&meta, "title", nil)   // the heading replaces a title kept in the header
        }
        self.text = joinFrontMatter(meta, text)
    }

    /// Links the note to one calendar event, or unlinks it with nil.
    mutating func link(to event: CalendarEvent?) {
        var (meta, body) = parts
        Self.set(&meta, "event", event?.id)
        Self.set(&meta, "event_title", event?.title)
        Self.set(&meta, "event_start", event?.start.formatted(.iso8601))
        Self.set(&meta, "event_categories", event.flatMap { $0.categories.isEmpty ? nil : $0.categories.joined(separator: ", ") })
        text = joinFrontMatter(meta, body)
    }

    private static func set(_ meta: inout NoteMeta, _ key: String, _ value: String?) {
        let index = meta.firstIndex { $0.key == key }
        switch (index, value) {
        case (let index?, let value?): meta[index].value = value
        case (let index?, nil): meta.remove(at: index)
        case (nil, let value?): meta.append((key, value))
        case (nil, nil): break
        }
    }
}

/// shortcut: one `key: value` per line; nested YAML in a header is dropped when the note is saved here. Use a YAML parser if notes need more.
func splitFrontMatter(_ text: String) -> (meta: NoteMeta, body: String) {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return ([], text) }
    let meta = lines[1..<end].compactMap { line -> (key: String, value: String)? in
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return (line[..<colon].trimmingCharacters(in: .whitespaces), value)
    }
    let body = lines[(end + 1)...].drop { $0.isEmpty }.joined(separator: "\n")
    return (meta, body)
}

func joinFrontMatter(_ meta: NoteMeta, _ body: String) -> String {
    guard !meta.isEmpty else { return body }
    let lines = meta.map { key, value in
        let needsQuotes = value.contains(": ") || value.contains(" #") || value.contains("\"")
        return "\(key): " + (needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : value)
    }
    return "---\n" + lines.joined(separator: "\n") + "\n---\n\n" + body
}

/// A file name OneDrive accepts that no other note has.
func noteFileName(for title: String, taken: [String]) -> String {
    let clean = title.components(separatedBy: CharacterSet(charactersIn: "\"*:<>?/\\|#%~")).joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    let base = clean.isEmpty ? "Note" : String(clean.prefix(80))
    var name = base + ".md", n = 2
    while taken.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
        name = "\(base) \(n).md"
        n += 1
    }
    return name
}

// MARK: Search

struct NoteHit: Identifiable {
    var note: Note
    var score: Double
    var snippet: String   // the first line that matches
    var id: String { note.name }
}

private func words(_ text: String) -> [String] {
    text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
}

/// Full-text search ranked with BM25; a query word also matches words it starts ("meet" finds "meeting"),
/// and the title counts double.
/// shortcut: keyword search over notes held in memory, no embeddings; add a vector index if meaning-based search is needed.
func searchNotes(_ notes: [Note], _ query: String, limit: Int = 10) -> [NoteHit] {
    let terms = Set(words(query))
    guard !terms.isEmpty, !notes.isEmpty else { return [] }
    let docs = notes.map { words($0.title + " " + $0.title + " " + $0.body) }
    let average = max(1, Double(docs.map(\.count).reduce(0, +)) / Double(docs.count))
    func matches(_ word: String, _ term: String) -> Bool { word.hasPrefix(term) }
    let containing = Dictionary(uniqueKeysWithValues: terms.map { term in
        (term, Double(docs.filter { $0.contains { matches($0, term) } }.count))
    })
    let hits = zip(notes, docs).compactMap { note, doc -> NoteHit? in
        var score = 0.0
        for term in terms {
            let frequency = Double(doc.filter { matches($0, term) }.count)
            guard frequency > 0 else { continue }
            let idf = log(1 + (Double(docs.count) - containing[term]! + 0.5) / (containing[term]! + 0.5))
            score += idf * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * Double(doc.count) / average))
        }
        guard score > 0 else { return nil }
        let lines = note.body.components(separatedBy: "\n").filter { !$0.hasPrefix("# ") }   // the title is shown anyway
        let line = lines.first { line in words(line).contains { word in terms.contains { matches(word, $0) } } }
            ?? lines.first { !$0.isEmpty } ?? ""
        return NoteHit(note: note, score: score, snippet: String(line.trimmingCharacters(in: .whitespaces).prefix(200)))
    }
    return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
}

// MARK: Formatting buttons

/// What a formatting button does to the text at the selection. Offsets count characters.
enum MarkdownAction {
    case insert(String)
    case wrap(String, String)   // around the selection, or an empty pair with the cursor inside
    case link(url: String?)     // the address if one is known (from the clipboard); a selected address becomes the link's target
    case list(String)           // start the selected lines with this, replacing another list marker
    case indent, dedent

    private static let markers = ["- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ "]

    /// The list marker a line starts with (after its indent), numbered ones included.
    static func marker(of content: Substring) -> String? {
        if let marker = markers.first(where: { content.hasPrefix($0) }) { return marker }
        let digits = content.prefix { $0.isNumber }
        return !digits.isEmpty && content.dropFirst(digits.count).hasPrefix(". ") ? digits + ". " : nil
    }

    /// What Return does at the end of a list line: start the next item, or, on an item with nothing in it, end the list.
    enum Continuation: Equatable { case next(String), end(markerLength: Int) }

    static func continuation(after line: String) -> Continuation? {
        let content = line.drop { $0 == " " }
        let indent = String(repeating: " ", count: line.count - content.count)
        guard let marker = marker(of: content) else { return nil }
        if content.count == marker.count { return .end(markerLength: indent.count + marker.count) }
        if marker.hasSuffix("] ") { return .next(indent + "- [ ] ") }
        if let number = Int(marker.dropLast(2)) { return .next(indent + "\(number + 1). ") }
        return .next(indent + marker)
    }

    func apply(to text: String, selection: Range<Int>) -> (text: String, selection: Range<Int>) {
        let chars = Array(text)
        let lower = min(max(selection.lowerBound, 0), chars.count), upper = min(max(selection.upperBound, lower), chars.count)
        let selected = String(chars[lower..<upper])
        func replacing(_ new: String, cursor: Int) -> (String, Range<Int>) {
            (String(chars[..<lower]) + new + String(chars[upper...]), lower + cursor..<lower + cursor)
        }
        switch self {
        case .insert(let string):
            return replacing(string, cursor: string.count)
        case .wrap(let open, let close):
            return replacing(open + selected + close, cursor: open.count + selected.count + (selected.isEmpty ? 0 : close.count))
        case .link(let url):
            if selected.hasPrefix("http://") || selected.hasPrefix("https://") { return replacing("[](\(selected))", cursor: 1) }
            let whole = "[\(selected)](\(url ?? ""))"
            // The cursor goes to whatever is still missing: the text, the address, or nothing.
            return replacing(whole, cursor: selected.isEmpty ? 1 : url == nil ? selected.count + 3 : whole.count)
        case .list, .indent, .dedent:
            let start = (chars[..<lower].lastIndex(of: "\n") ?? -1) + 1
            let end = chars[upper...].firstIndex(of: "\n") ?? chars.count
            let lines = String(chars[start..<end]).components(separatedBy: "\n").map { line -> String in
                let content = line.drop { $0 == " " }
                let spaces = String(repeating: " ", count: line.count - content.count)
                switch self {
                case .indent: return "  " + line
                case .dedent: return String(line.dropFirst(min(2, spaces.count)))
                case .list(let marker):
                    let old = Self.marker(of: content) ?? ""
                    return spaces + marker + content.dropFirst(old.count)
                default: return line
                }
            }
            .enumerated().map { index, line in   // a numbered list counts up
                if case .list("1. ") = self { return line.replacingOccurrences(of: "1. ", with: "\(index + 1). ", options: .anchored, range: line.range(of: "1. ")) }
                return line
            }
            .joined(separator: "\n")
            let cursor = max(start, upper + lines.count - (end - start))
            return (String(chars[..<start]) + lines + String(chars[end...]), cursor..<cursor)
        }
    }
}
