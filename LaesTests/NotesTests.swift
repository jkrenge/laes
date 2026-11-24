import Foundation
import Testing
@testable import Laes

@Test func noteTitleIsItsHeadingAndTheHeaderLinksAnEvent() {
    var note = Note(name: "a.md", text: "---\ntags: [work, 1:1]\ntitle: \"Plan: Q1\"\n---\n\ntext")
    #expect(note.title == "Plan: Q1")   // written elsewhere, title in the header
    note.update(title: "Plan")
    #expect(note.title == "Plan" && note.body == "# Plan\n\ntext" && note.meta("title") == nil)
    let event = CalendarEvent(id: "EV1", title: "Check-in", start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600))
    note.link(to: event)
    note.update(body: "# New\nbody")
    #expect(note.eventID == "EV1" && note.eventStart == event.start && note.eventCategories.isEmpty)
    var tagged = event
    tagged.categories = ["Private", "Family"]
    note.link(to: tagged)
    #expect(note.eventCategories == ["Private", "Family"])
    note.link(to: event)
    #expect(note.text.hasPrefix("---\ntags: [work, 1:1]\nevent: EV1\n"))
    #expect(note.title == "New")
    note.link(to: nil)
    #expect(note.eventID == nil && note.meta("event_title") == nil)
    #expect(Note(name: "Plain.md", text: "no header").title == "Plain")
    #expect(Note(name: "Untitled.md", text: "# ").isBlank && !note.isBlank)
}

@Test func formattingButtonsEditAtTheSelection() {
    func run(_ action: MarkdownAction, _ text: String, _ selection: Range<Int>) -> String {
        let result = action.apply(to: text, selection: selection)
        var out = Array(result.text)
        out.insert("|", at: result.selection.lowerBound)
        return String(out)
    }
    #expect(run(.wrap("**", "**"), "a word", 2..<6) == "a **word**|")
    #expect(run(.wrap("**", "**"), "a ", 2..<2) == "a **|**")
    #expect(run(.link(url: nil), "see docs", 4..<8) == "see [docs](|)")
    #expect(run(.link(url: "https://a.io"), "see docs", 4..<8) == "see [docs](https://a.io)|")
    #expect(run(.link(url: "https://a.io"), "see ", 4..<4) == "see [|](https://a.io)")
    #expect(run(.link(url: nil), "https://b.io", 0..<12) == "[|](https://b.io)")
    #expect(run(.insert("#"), "", 0..<0) == "#|")
    #expect(run(.list("- [ ] "), "one\n  - two\nthree", 1..<9) == "- [ ] one\n  - [ ] t|wo\nthree")
    #expect(run(.indent, "a\nb", 2..<2) == "a\n  |b")
    #expect(run(.dedent, "a\n   b", 5..<5) == "a\n |b")
    #expect(run(.dedent, "a", 0..<0) == "|a")
}

@Test func noteSearchRanksByRelevanceAndMatchesWordStarts() {
    let notes = [
        Note(name: "a.md", text: "Budget for the offsite.\nWe meet in Lisbon."),
        Note(name: "b.md", text: "---\ntitle: Pricing meeting\n---\n\nDiscussed pricing tiers.\nPricing goes up in Q2."),
        Note(name: "c.md", text: "Groceries"),
    ]
    let hits = searchNotes(notes, "pricing meet")
    #expect(hits.map(\.note.name) == ["b.md", "a.md"])
    #expect(hits[0].snippet == "Discussed pricing tiers.")
    #expect(searchNotes(notes, "  ").isEmpty)
}

@Test func noteFileNamesAreLegalAndUnique() {
    #expect(noteFileName(for: "Q1: plan / draft?", taken: []) == "Q1  plan   draft.md")
    #expect(noteFileName(for: "Plan", taken: ["plan.md", "Plan 2.md"]) == "Plan 3.md")
    #expect(noteFileName(for: " . ", taken: []) == "Note.md")
}
