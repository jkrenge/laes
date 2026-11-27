import Testing
import AppKit
@testable import Laes

/// The Mac note editor's typing rules, driven the way keys and clicks reach it. "|" marks the cursor.
@MainActor struct MarkdownEditorTests {
    private func editor(_ text: String) -> MarkdownTextView {
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.copiedURL = { nil }   // not the clipboard of whoever runs the tests
        view.isRichText = false
        view.isEditable = true
        let cursor = (text as NSString).range(of: "|")
        view.string = text.replacingOccurrences(of: "|", with: "")
        view.setSelectedRange(NSRange(location: cursor.location, length: 0))
        return view
    }

    private func shown(_ view: MarkdownTextView) -> String {
        let text = NSMutableString(string: view.string)
        text.insert("|", at: view.selectedRange().location + view.selectedRange().length)
        return text as String
    }

    private func type(_ view: MarkdownTextView, _ keys: String) {
        for key in keys { view.insertText(String(key), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    @Test func marksComeInPairsAndDouble() {
        let view = editor("make |")
        type(view, "**")
        #expect(shown(view) == "make **|**")
        type(view, "bold**")
        #expect(shown(view) == "make **bold**|")
        let snake = editor("snake|")
        type(snake, "_case")
        #expect(shown(snake) == "snake_case|")   // inside a word: no pair
        let bullet = editor("|")
        type(bullet, "* ")
        #expect(shown(bullet) == "* |")   // a * starting a line is a bullet
    }

    @Test func backspaceInAnEmptyPairTakesBoth() {
        let view = editor("a |")
        type(view, "`")
        view.deleteBackward(nil)
        #expect(shown(view) == "a |")
    }

    @Test func aSelectionIsWrapped() {
        let view = editor("one two")
        view.setSelectedRange(NSRange(location: 4, length: 3))
        type(view, "_")
        #expect(view.string == "one _two_" && view.selectedRange() == NSRange(location: 5, length: 3))
    }

    @Test func returnContinuesAndEndsLists() {
        let view = editor("- milk|")
        view.insertNewline(nil)
        #expect(shown(view) == "- milk\n- |")
        view.insertNewline(nil)
        #expect(shown(view) == "- milk\n|")
        let numbered = editor("1. one|")
        numbered.insertNewline(nil)
        #expect(shown(numbered) == "1. one\n2. |")
        let todo = editor("- [x] done|")
        todo.insertNewline(nil)
        #expect(shown(todo) == "- [x] done\n- [ ] |")
    }

    @Test func formatsToggle() {
        let view = editor("a word")
        view.setSelectedRange(NSRange(location: 2, length: 4))
        view.apply(.bold)
        #expect(view.string == "a **word**" && view.selectedRange() == NSRange(location: 4, length: 4))
        view.apply(.bold)
        #expect(view.string == "a word")
        view.apply(.underline)
        #expect(view.string == "a <u>word</u>")
        let lines = editor("a\nb")
        lines.setSelectedRange(NSRange(location: 0, length: 3))
        lines.apply(.numberedList)
        #expect(lines.string == "1. a\n2. b")
        lines.setSelectedRange(NSRange(location: 0, length: (lines.string as NSString).length))
        lines.apply(.numberedList)
        #expect(lines.string == "a\nb")
    }

    @Test func doubleClickStartsEditingWhereClicked() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView = view
        view.string = "first line\nsecond line"
        view.isEditable = false
        var started = false
        view.onStartEditing = { started = true }
        let layout = try #require(view.layoutManager)
        let glyph = layout.glyphIndexForCharacter(at: 14)   // inside "second"
        let point = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: try #require(view.textContainer)).origin
        let inWindow = view.convert(NSPoint(x: point.x + 1 + view.textContainerOrigin.x, y: point.y + 4 + view.textContainerOrigin.y), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        view.mouseDown(with: click)
        #expect(started && view.isEditable && abs(view.selectedRange().location - 14) <= 1)
    }

    @Test func commandSFinishesAndCommandMinusStrikes() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let view = editor("a word")
        window.contentView = view
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 2, length: 4))
        func press(_ key: String) throws -> Bool {
            try view.performKeyEquivalent(with: #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)))
        }
        #expect(try press("-") && view.string == "a ~~word~~")
        var ended = false
        view.onEndEditing = { ended = true }
        #expect(try press("s") && ended && view.string == "a ~~word~~")
    }

    @Test func boldIsBoldAndItsMarksAreDimmed() throws {
        let storage = NSTextStorage(string: "a **b** c")
        MarkdownStyler.style(storage)
        let font = try #require(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == NSColor.tertiaryLabelColor)
    }

    @Test func marksAndToDoBoxesAreTagged() {
        let storage = NSTextStorage(string: "- [ ] a **b**\n- [x] c")
        MarkdownStyler.style(storage)
        #expect(storage.attribute(.markdownSyntax, at: 0, effectiveRange: nil) != nil)   // the dash
        #expect(storage.attribute(.markdownSyntax, at: 8, effectiveRange: nil) != nil)   // **
        #expect(storage.attribute(.markdownSyntax, at: 10, effectiveRange: nil) == nil)  // b
        #expect(storage.attribute(.markdownTask, at: 3, effectiveRange: nil) as? Bool == false)
        #expect(storage.attribute(.markdownTask, at: 17, effectiveRange: nil) as? Bool == true)
    }

    @Test func listItemsWrapUnderTheirTextAndDoneToDosAreStruckThrough() throws {
        let storage = NSTextStorage(string: "- [x] done\n- [ ] open\nplain")
        MarkdownStyler.style(storage, editing: false)
        let reading = try #require(storage.attribute(.paragraphStyle, at: 13, effectiveRange: nil) as? NSParagraphStyle)
        MarkdownStyler.style(storage, editing: true)
        let editing = try #require(storage.attribute(.paragraphStyle, at: 13, effectiveRange: nil) as? NSParagraphStyle)
        #expect(reading.headIndent > 0 && editing.headIndent > reading.headIndent)   // "[ ] " out of editing, "- [ ] " in it
        #expect((storage.attribute(.paragraphStyle, at: 23, effectiveRange: nil) as? NSParagraphStyle)?.headIndent == 0)
        #expect(storage.attribute(.strikethroughStyle, at: 7, effectiveRange: nil) != nil)
        #expect(storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor == NSColor.secondaryLabelColor)
        #expect(storage.attribute(.strikethroughStyle, at: 18, effectiveRange: nil) == nil)
    }

    @Test func aClickOnABoxTicksTheToDoWithoutEditing() {
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        view.textStorage?.delegate = nil
        view.string = "- [ ] call"
        view.isEditable = false
        var toggled = false
        view.onToggleTask = { toggled = true }
        let box = NSRange(location: 2, length: 3)
        if let storage = view.textStorage { MarkdownStyler.style(storage, editing: false) }
        view.toggleTask(box)
        #expect(view.string == "- [x] call" && toggled)
        view.toggleTask(box)
        #expect(view.string == "- [ ] call")
    }

    @Test func linksPutPlaceholdersAndTabBetweenThem() {
        let view = editor("see |")
        view.apply(.link)
        #expect(view.string == "see [label](url)" && view.selectedRange() == NSRange(location: 5, length: 5))
        type(view, "docs")
        view.insertTab(nil)
        #expect(view.string == "see [docs](url)" && view.selectedRange() == NSRange(location: 11, length: 3))
        view.insertBacktab(nil)
        #expect(view.selectedRange() == NSRange(location: 5, length: 4))
        view.insertTab(nil)
        type(view, "x")
        view.insertTab(nil)
        #expect(shown(view) == "see [docs](x)|")
        let word = editor("read the guide")
        word.setSelectedRange(NSRange(location: 9, length: 5))
        word.apply(.link)
        #expect(word.string == "read the [guide](url)" && word.selectedRange() == NSRange(location: 17, length: 3))
        let copied = editor("|")
        copied.copiedURL = { "https://a.io" }
        copied.apply(.link)
        #expect(copied.string == "[label](https://a.io)" && copied.selectedRange() == NSRange(location: 1, length: 5))
    }

    @Test func aListButtonsMarkerIsStyledToo() throws {
        let model = MarkdownEditorModel()
        let coordinator = MarkdownEditor(text: .constant(""), isEditing: .constant(true), model: model).makeCoordinator()
        let view = editor("x\n\nNotes are plain")
        view.textStorage?.delegate = coordinator
        view.setSelectedRange(NSRange(location: 3, length: 5))
        view.apply(.bulletList)
        let color = view.textStorage?.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        #expect(view.string == "x\n\n- Notes are plain")
        #expect(color != NSColor.labelColor, "dash color \(String(describing: color))")
    }
}
