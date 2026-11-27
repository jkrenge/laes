#if os(macOS)
import AppKit
import SwiftUI

/// The formatting a note offers on the Mac, with its ⌘ shortcut.
enum NoteFormat: CaseIterable, Identifiable {
    case bold, italic, underline, strikethrough, bulletList, numberedList, taskList, link
    var id: Self { self }

    var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .bulletList: "Bulleted List"
        case .numberedList: "Numbered List"
        case .taskList: "To-Do List"
        case .link: "Link"
        }
    }

    var key: Character {
        switch self {
        case .bold: "b"
        case .italic: "i"
        case .underline: "u"
        case .strikethrough: "-"
        case .bulletList: "l"
        case .numberedList: "o"
        case .taskList: "t"
        case .link: "k"
        }
    }

    var icon: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .taskList: "checklist"
        case .link: "link"
        }
    }

    /// The Markdown around a selection, for the styles; nil for lists and links.
    var wrap: (open: String, close: String)? {
        switch self {
        case .bold: ("**", "**")
        case .italic: ("*", "*")
        case .underline: ("<u>", "</u>")
        case .strikethrough: ("~~", "~~")
        default: nil
        }
    }

    var listMarker: String? {
        switch self {
        case .bulletList: "- "
        case .numberedList: "1. "
        case .taskList: "- [ ] "
        default: nil
        }
    }
}

/// What the floating format pill needs from the text view, and the way back to it.
@Observable final class MarkdownEditorModel {
    var anchor: CGRect?   // the selection, or the cursor, in the editor's visible area (y down)
    var hasSelection = false
    var commandHeld = false
    var pinned = false   // shown by holding ⌘: stays after ⌘ is let go, so its buttons can be clicked, until the cursor moves
    @ObservationIgnored weak var textView: MarkdownTextView?

    var showsPill: Bool { anchor != nil && (hasSelection || commandHeld || pinned) }
    func apply(_ format: NoteFormat) { textView?.apply(format) }
}

/// A note's Markdown, styled as it is typed: bold looks bold, with its ** still there, dimmed. Read-only until
/// double-clicked (or Edit); Escape ends editing. Return continues a list; *, _, ` and ~ come in pairs.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    let model: MarkdownEditorModel
    var topInset: CGFloat = 56   // the floating buttons sit above the start of the text; it scrolls under them
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let textView = MarkdownTextView(usingTextLayoutManager: false)   // TextKit 1: its layout manager gives the pill its place
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: topInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.layoutManager?.delegate = context.coordinator
        context.coordinator.textView = textView   // before the text, which is styled for reading or editing
        textView.string = text
        textView.isEditable = isEditing
        textView.setAccessibilityLabel("Note")
        let coordinator = context.coordinator
        textView.onToggleTask = { coordinator.textDidChange(Notification(name: NSText.didChangeNotification)) }
        textView.onStartEditing = { if coordinator.parent.isEnabled { coordinator.parent.isEditing = true } }
        textView.onEndEditing = { coordinator.parent.isEditing = false }
        textView.onCommandHeld = { held in
            coordinator.parent.model.commandHeld = held
            if held { coordinator.parent.model.pinned = true }
            coordinator.updatePill()
        }
        model.textView = textView
        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? MarkdownTextView else { return }
        if textView.string != text, !textView.hasMarkedText() { textView.string = text }   // changed elsewhere, by an AI tool say
        textView.isSelectable = isEnabled   // hidden behind another view: not reachable with Tab either
        guard textView.isEditable != (isEditing && isEnabled) else { return }
        textView.isEditable = isEditing && isEnabled
        if textView.isEditable {
            // Started with Edit rather than a double-click: the cursor goes to the end.
            DispatchQueue.main.async {
                guard textView.window?.firstResponder !== textView else { return }
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                textView.window?.makeFirstResponder(textView)
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        } else {
            textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
            if textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
            model.commandHeld = false
            model.pinned = false
            context.coordinator.updatePill()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, NSLayoutManagerDelegate {
        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?
        init(parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            // The styles are redone for the whole note on each change; show all of it, not only the edited part.
            textView.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if !parent.model.commandHeld { parent.model.pinned = false }
            updatePill()
        }

        @objc func scrolled() { updatePill() }

        func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
            if editedMask.contains(.editedCharacters) { MarkdownStyler.style(storage, editing: textView?.isEditable ?? false) }
        }

        /// Out of editing, the Markdown marks take no glyphs: **b** reads as a bold b.
        func layoutManager(_ manager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                           properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                           font: NSFont, forGlyphRange range: NSRange) -> Int {
            guard textView?.isEditable == false, let storage = manager.textStorage else { return 0 }
            var hidden = Array(UnsafeBufferPointer(start: properties, count: range.length)), changed = false
            for i in hidden.indices where storage.attribute(.markdownSyntax, at: characterIndexes[i], effectiveRange: nil) != nil {
                hidden[i] = .null
                changed = true
            }
            guard changed else { return 0 }
            manager.setGlyphs(glyphs, properties: hidden, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
            return range.length
        }

        func updatePill() {
            guard let textView, textView.isEditable else {
                parent.model.anchor = nil
                parent.model.hasSelection = false
                return
            }
            let range = textView.selectedRange()
            parent.model.hasSelection = range.length > 0
            parent.model.anchor = textView.visibleRect(of: range)
        }
    }
}

final class MarkdownTextView: NSTextView {
    override var isEditable: Bool {
        didSet {   // the marks show only while editing: style and lay the glyphs out again
            guard oldValue != isEditable, let manager = layoutManager, let storage = textStorage else { return }
            MarkdownStyler.style(storage, editing: isEditable)
            let all = NSRange(location: 0, length: (string as NSString).length)
            manager.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
            manager.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
            needsDisplay = true
        }
    }

    /// A to-do's [ ] or [x] (its text drawn clear) gets a box drawn over it.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage else { return }
        let visible = manager.characterRange(forGlyphRange: manager.glyphRange(forBoundingRect: visibleRect, in: container), actualGlyphRange: nil)
        let color = NSColor(Color.brandText)
        storage.enumerateAttribute(.markdownTask, in: visible) { value, range, _ in
            guard let done = value as? Bool else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let line = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? MarkdownStyler.font
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular).applying(.init(paletteColors: [color]))
            guard let box = NSImage(systemSymbolName: done ? "checkmark.square" : "square", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            let origin = textContainerOrigin
            let baseline = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY + manager.location(forGlyphAt: glyphs.location).y
            let rect = NSRect(x: origin.x + line.midX - box.size.width / 2, y: origin.y + baseline - font.capHeight / 2 - box.size.height / 2,
                              width: box.size.width, height: box.size.height)
            box.draw(in: rect)
        }
    }

    var onToggleTask: (() -> Void)?
    var onStartEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onCommandHeld: ((Bool) -> Void)?
    var copiedURL: () -> String? = {   // a web address on the clipboard, for a new link; tests replace it
        let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return copied.flatMap { $0.hasPrefix("http://") || $0.hasPrefix("https://") ? $0 : nil }
    }
    private var holdTimer: Timer?
    private var freshPair: Int?   // just inside a pair typed a moment ago, like *|*

    // MARK: Reading and editing

    /// A double-click anywhere starts editing right there; single clicks still select, for copying, or tick a to-do.
    override func mouseDown(with event: NSEvent) {
        if !isEditable, isSelectable, event.clickCount == 1, let box = taskBox(at: convert(event.locationInWindow, from: nil)) {
            return toggleTask(box)
        }
        guard !isEditable, isSelectable, event.clickCount == 2 else { return super.mouseDown(with: event) }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        isEditable = true
        setSelectedRange(NSRange(location: index, length: 0))
        window?.makeFirstResponder(self)
        onStartEditing?()
    }

    /// The [ ] or [x] of the to-do box under a point.
    func taskBox(at point: NSPoint) -> NSRange? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = manager.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        var box = NSRange()
        guard index < storage.length, storage.attribute(.markdownTask, at: index, effectiveRange: &box) != nil else { return nil }
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: box, actualCharacterRange: nil), in: container)
        return rect.insetBy(dx: -4, dy: -2).contains(local) ? box : nil
    }

    /// Ticks a to-do, or unticks it, without editing: [ ] becomes [x].
    func toggleTask(_ box: NSRange) {
        let mark = NSRange(location: box.location + 1, length: 1)
        textStorage?.replaceCharacters(in: mark, with: (string as NSString).substring(with: mark) == " " ? "x" : " ")
        needsDisplay = true
        onToggleTask?()
    }

    /// Escape.
    override func cancelOperation(_ sender: Any?) {
        if isEditable { onEndEditing?() } else { super.cancelOperation(sender) }
    }

    // MARK: Typing

    /// Return on a list line starts the next item; on an empty item it ends the list.
    override func insertNewline(_ sender: Any?) {
        freshPair = nil
        let text = string as NSString, selection = selectedRange()
        guard isEditable, !hasMarkedText(), selection.length == 0 else { return super.insertNewline(sender) }
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let end = line.location + line.length - (text.substring(with: line).hasSuffix("\n") ? 1 : 0)
        let content = text.substring(with: NSRange(location: line.location, length: end - line.location))
        let leading = content.prefix { $0 == " " }
        guard let marker = MarkdownAction.marker(of: content.dropFirst(leading.count)),
              selection.location >= line.location + leading.count + marker.utf16.count,
              let next = MarkdownAction.continuation(after: content) else { return super.insertNewline(sender) }
        switch next {
        case .next(let prefix): replace(selection, with: "\n" + prefix, cursor: selection.location + 1 + prefix.utf16.count)
        case .end(let length): replace(NSRange(location: line.location, length: length), with: "", cursor: line.location)
        }
    }

    /// *, _, ` and ~ come in pairs: around a selection, or empty with the cursor inside. Typed again inside an empty
    /// pair they double (**|**); in front of the closing one they step over it.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard isEditable, !hasMarkedText(), let typed = string as? String, typed.count == 1, let mark = typed.first,
              "*_`~".contains(mark) else {
            freshPair = nil
            return super.insertText(string, replacementRange: replacementRange)
        }
        let text = self.string as NSString
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if selection.length > 0 {
            replace(selection, with: typed + text.substring(with: selection) + typed,
                    select: NSRange(location: selection.location + 1, length: selection.length))
            return
        }
        let at = selection.location
        let before = at > 0 ? text.substring(with: NSRange(location: at - 1, length: 1)).first : nil
        let after = at < text.length ? text.substring(with: NSRange(location: at, length: 1)).first : nil
        if freshPair == at, before == mark, after == mark {
            replace(selection, with: typed + typed, cursor: at + 1)
            freshPair = at + 1
            return
        }
        if after == mark, let before, !before.isWhitespace {
            freshPair = nil
            setSelectedRange(NSRange(location: at + 1, length: 0))
            return
        }
        let lineStart = text.lineRange(for: NSRange(location: at, length: 0)).location
        let startsLine = text.substring(with: NSRange(location: lineStart, length: at - lineStart)).allSatisfy { $0 == " " }
        let opens = !(before?.isLetter ?? false) && !(before?.isNumber ?? false)
            && (after.map { $0.isWhitespace || ".,;:!?)".contains($0) } ?? true)
        if opens, !(startsLine && mark == "*") {   // a * starting a line is a bullet
            replace(selection, with: typed + typed, cursor: at + 1)
            freshPair = at + 1
            return
        }
        freshPair = nil
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Backspace in an empty pair takes both halves.
    override func deleteBackward(_ sender: Any?) {
        let text = string as NSString, selection = selectedRange()
        if freshPair == selection.location, selection.length == 0, selection.location > 0, selection.location < text.length,
           text.character(at: selection.location - 1) == text.character(at: selection.location) {
            freshPair = nil
            return replace(NSRange(location: selection.location - 1, length: 2), with: "", cursor: selection.location - 1)
        }
        freshPair = nil
        super.deleteBackward(sender)
    }

    // MARK: Shortcuts and the pill

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEditable, window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased().first else { return super.performKeyEquivalent(with: event) }
        holdTimer?.invalidate()
        if key == "s" { onEndEditing?(); return true }   // ⌘S: done editing, which saves
        guard let format = NoteFormat.allCases.first(where: { $0.key == key }) else { return super.performKeyEquivalent(with: event) }
        apply(format)
        return true
    }

    /// Holding ⌘ for a moment shows the pill with each shortcut.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        holdTimer?.invalidate()
        if isEditable, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.onCommandHeld?(true) }
            }
        } else {
            onCommandHeld?(false)
        }
    }

    /// Applies a style or list to the selection, or takes it off again if it is already there.
    func apply(_ format: NoteFormat) {
        guard isEditable else { return }
        let text = string as NSString, selection = selectedRange()
        if let (open, close) = format.wrap {
            if let unwrapped = unwrap(selection, open: open, close: close, in: text) {
                return replace(unwrapped.range, with: unwrapped.inner, select: NSRange(location: unwrapped.range.location, length: (unwrapped.inner as NSString).length))
            }
            // The text stays selected, so another style can follow (or this one come off again).
            let inner = text.substring(with: selection)
            return replace(selection, with: open + inner + close, select: NSRange(location: selection.location + (open as NSString).length, length: selection.length))
        }
        guard let marker = format.listMarker else { return insertLink(at: selection, in: text) }
        let action = MarkdownAction.list(linesHave(marker, selection, in: text) ? "" : marker)
        let source = string
        guard let range = Range(selection, in: source) else { return }
        let result = action.apply(to: source, selection: source.distance(from: source.startIndex, to: range.lowerBound)..<source.distance(from: source.startIndex, to: range.upperBound))
        let new = result.text
        let lower = new.index(new.startIndex, offsetBy: result.selection.lowerBound)
        let upper = new.index(new.startIndex, offsetBy: result.selection.upperBound)
        replaceAll(with: new, select: NSRange(lower..<upper, in: new))
    }

    /// [label](url), with whatever is still missing selected as a placeholder: the label first; Tab goes on to the address.
    /// A selected address becomes the link's target, selected text its label, a copied address its target.
    private func insertLink(at selection: NSRange, in text: NSString) {
        let selected = text.substring(with: selection)
        let isAddress = selected.hasPrefix("http://") || selected.hasPrefix("https://")
        let label = isAddress || selected.isEmpty ? "label" : selected
        let url = isAddress ? selected : copiedURL() ?? "url"
        let link = "[\(label)](\(url))" as NSString
        let start = selection.location
        let select = label == "label" ? NSRange(location: start + 1, length: 5)
            : url == "url" ? NSRange(location: start + link.length - 4, length: 3)
            : NSRange(location: start + link.length, length: 0)
        replace(selection, with: link as String, select: select)
    }

    /// Tab inside a link moves from its label to its address, then past it; Shift-Tab goes back. Elsewhere, a tab.
    override func insertTab(_ sender: Any?) {
        guard isEditable, let (label, url, end) = link(around: selectedRange()) else { return super.insertTab(sender) }
        let at = selectedRange().location
        setSelectedRange(NSLocationInRange(at, NSRange(location: label.location, length: label.length + 1)) ? url : NSRange(location: end, length: 0))
    }

    override func insertBacktab(_ sender: Any?) {
        guard isEditable, let (label, url, _) = link(around: selectedRange()),
              NSLocationInRange(selectedRange().location, NSRange(location: url.location, length: url.length + 1)) else { return super.insertBacktab(sender) }
        setSelectedRange(label)
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"\[([^\]\n]*)\]\(([^)\n]*)\)"#)

    /// The link the cursor is in: its label, its address, and where it ends.
    private func link(around selection: NSRange) -> (label: NSRange, url: NSRange, end: Int)? {
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        guard let match = Self.linkPattern.matches(in: string, range: line).first(where: {
            NSLocationInRange(selection.location, NSRange(location: $0.range.location, length: $0.range.length))
        }) else { return nil }
        return (match.range(at: 1), match.range(at: 2), match.range.location + match.range.length)
    }

    /// The selection with its markers, if it is already wrapped in them (just outside it, or as its own ends).
    private func unwrap(_ selection: NSRange, open: String, close: String, in text: NSString) -> (range: NSRange, inner: String)? {
        let o = (open as NSString).length, c = (close as NSString).length
        if selection.location >= o, selection.location + selection.length + c <= text.length,
           text.substring(with: NSRange(location: selection.location - o, length: o)) == open,
           text.substring(with: NSRange(location: selection.location + selection.length, length: c)) == close {
            return (NSRange(location: selection.location - o, length: o + selection.length + c), text.substring(with: selection))
        }
        let selected = text.substring(with: selection)
        if selection.length >= o + c, selected.hasPrefix(open), selected.hasSuffix(close) {
            return (selection, String(selected.dropFirst(open.count).dropLast(close.count)))
        }
        return nil
    }

    /// Every selected line already is this kind of list item (any number, for numbered lists).
    private func linesHave(_ marker: String, _ selection: NSRange, in text: NSString) -> Bool {
        text.substring(with: text.lineRange(for: selection)).split(separator: "\n").allSatisfy { line in
            guard let found = MarkdownAction.marker(of: line.drop { $0 == " " }) else { return false }
            return marker == "1. " ? found.first?.isNumber == true : found.lowercased() == marker
        }
    }

    /// The selection's (or cursor's) rectangle in the visible part of the scroll view, y down.
    func visibleRect(of range: NSRange) -> CGRect? {
        guard let layoutManager, let textContainer, let clip = enclosingScrollView?.contentView else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        if range.length == 0 {   // the cursor: the line it sits in
            let index = min(range.location, max(layoutManager.numberOfGlyphs - 1, 0))
            if layoutManager.numberOfGlyphs > 0 {
                rect = CGRect(x: rect.minX, y: layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: nil).minY,
                              width: 1, height: layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: nil).height)
            }
        }
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return clip.convert(rect, from: self).offsetBy(dx: -clip.bounds.minX, dy: -clip.bounds.minY)
    }

    // MARK: Edits that undo as one step

    private func replace(_ range: NSRange, with string: String, cursor: Int) {
        replace(range, with: string, select: NSRange(location: cursor, length: 0))
    }

    private func replace(_ range: NSRange, with string: String, select: NSRange) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
        setSelectedRange(select)
    }

    /// Only the part that changed, so undo and the scroll position stay calm.
    private func replaceAll(with new: String, select: NSRange) {
        let old = string as NSString, next = new as NSString
        var prefix = 0, suffix = 0
        while prefix < old.length, prefix < next.length, old.character(at: prefix) == next.character(at: prefix) { prefix += 1 }
        while suffix < old.length - prefix, suffix < next.length - prefix,
              old.character(at: old.length - 1 - suffix) == next.character(at: next.length - 1 - suffix) { suffix += 1 }
        replace(NSRange(location: prefix, length: old.length - prefix - suffix),
                with: next.substring(with: NSRange(location: prefix, length: next.length - prefix - suffix)), select: select)
    }
}

/// Markdown made visible as it is typed: headings, bold, italic, strikethrough, underline, code and links take
/// their look, and the characters that make them stay, dimmed. List markers and to-do boxes are coloured.
enum MarkdownStyler {
    static let font = NSFont.systemFont(ofSize: 14)
    private static func pattern(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }
    private static let heading = pattern(#"^(#{1,6} )(.*)$"#)
    private static let bold = pattern(#"(\*\*|__)(?=\S)(.+?)(?<=\S)(\1)"#)
    private static let italic = pattern(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])(\1)(?![*_\w])"#)
    private static let strike = pattern(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#)
    private static let underline = pattern(#"(<u>)(.+?)(</u>)"#)
    private static let code = pattern(#"(`)([^`\n]+)(`)"#)
    private static let link = pattern(#"(\[)([^\]\n]*)(\]\([^)\n]*\))"#)
    private static let list = pattern(#"^ *([-*+] \[[ xX]\]|[-*+]|\d+\.)(?= )"#)
    private static let task = pattern(#"^ *([-*+] )(\[([ xX])\])(?= )"#)
    private static let item = pattern(#"^( *)([-*+] \[[ xX]\] |[-*+] |\d+\. )"#)

    /// `editing`: the marks show, so a list item's wrapped lines line up after more of them.
    static func style(_ storage: NSTextStorage, editing: Bool = true) {
        let text = storage.string, all = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: all)
        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: text, range: all) { match, _, _ in if let match { body(match) } }
        }
        func dim(_ range: NSRange) {   // a mark: dimmed while editing, gone otherwise
            storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor, .markdownSyntax: true], range: range)
        }
        func trait(_ trait: NSFontTraitMask, _ range: NSRange) {
            storage.enumerateAttribute(.font, in: range) { value, part, _ in
                storage.addAttribute(.font, value: NSFontManager.shared.convert(value as? NSFont ?? font, toHaveTrait: trait), range: part)
            }
        }
        each(heading) { match in
            let level = match.range(at: 1).length - 1
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: [22, 18, 16, 15, 14, 14][level - 1], weight: level <= 2 ? .bold : .semibold), range: match.range)
            dim(match.range(at: 1))
        }
        each(bold) { trait(.boldFontMask, $0.range(at: 2)); dim($0.range(at: 1)); dim($0.range(at: 3)) }
        each(italic) { trait(.italicFontMask, $0.range(at: 2)); dim($0.range(at: 1)); dim($0.range(at: 3)) }
        each(strike) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: $0.range(at: 2))
            dim($0.range(at: 1)); dim($0.range(at: 3))
        }
        each(underline) {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: $0.range(at: 2))
            dim($0.range(at: 1)); dim($0.range(at: 3))
        }
        each(code) {
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                   .backgroundColor: NSColor.quaternaryLabelColor], range: $0.range(at: 2))
            dim($0.range(at: 1)); dim($0.range(at: 3))
        }
        each(link) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: $0.range(at: 2))
            dim($0.range(at: 1)); dim($0.range(at: 3))
        }
        each(list) { storage.addAttribute(.foregroundColor, value: NSColor(Color.brandText), range: $0.range(at: 1)) }
        // A list item's wrapped lines start where its text does, past the marker (a to-do's "- " is hidden out of editing).
        each(item) { match in
            let marker = (text as NSString).substring(with: match.range(at: 2))
            let shown = marker.hasSuffix("] ") ? (editing ? "- [ ] " : "[ ] ") : marker
            let hanging = paragraph.mutableCopy() as! NSMutableParagraphStyle
            hanging.headIndent = (String(repeating: " ", count: match.range(at: 1).length) + shown as NSString).size(withAttributes: [.font: font]).width
            storage.addAttribute(.paragraphStyle, value: hanging, range: (text as NSString).paragraphRange(for: match.range))
        }
        each(task) {
            if editing {
                storage.addAttribute(.markdownSyntax, value: true, range: $0.range(at: 1))
            } else {
                // The "- " takes no room rather than no glyphs: a line starting with hidden glyphs gets its wrapped lines' indent.
                for i in 0..<$0.range(at: 1).length {
                    let char = NSRange(location: $0.range(at: 1).location + i, length: 1)
                    let width = ((text as NSString).substring(with: char) as NSString).size(withAttributes: [.font: font]).width
                    storage.addAttributes([.foregroundColor: NSColor.clear, .kern: -width], range: char)
                }
            }
            storage.addAttributes([.foregroundColor: NSColor.clear, .markdownTask: (text as NSString).substring(with: $0.range(at: 3)) != " "],
                                  range: $0.range(at: 2))
            // An x is wider than a space: kerned to its width, done and open to-dos start their text at the same place.
            let x = (text as NSString).substring(with: $0.range(at: 3)) as NSString
            storage.addAttribute(.kern, value: (" " as NSString).size(withAttributes: [.font: font]).width - x.size(withAttributes: [.font: font]).width,
                                 range: $0.range(at: 3))
            guard x != " " else { return }
            // Done: the rest of the line greyed out and struck through.
            let line = (text as NSString).lineRange(for: $0.range)
            let start = $0.range(at: 2).location + $0.range(at: 2).length
            let rest = NSRange(location: start, length: line.location + line.length - start - ((text as NSString).substring(with: line).hasSuffix("\n") ? 1 : 0))
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: rest)
            storage.enumerateAttribute(.foregroundColor, in: rest) { color, part, _ in
                if color as? NSColor == NSColor.labelColor { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: part) }
            }
        }
    }
}

extension NSAttributedString.Key {
    static let markdownSyntax = NSAttributedString.Key("laes.markdownSyntax")   // a mark, hidden out of editing
    static let markdownTask = NSAttributedString.Key("laes.markdownTask")   // a to-do box: true when done
}
#endif
