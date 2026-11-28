import Foundation
import SwiftUI
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
    #expect(run(.list("1. "), "a\n- b\nc", 0..<7) == "1. a\n2. b\n3. c|")
    #expect(run(.list(""), "- [ ] a\n12. b", 0..<13) == "a\nb|")
}

@Test func returnContinuesALineOfAList() {
    #expect(MarkdownAction.continuation(after: "- milk") == .next("- "))
    #expect(MarkdownAction.continuation(after: "  * eggs") == .next("  * "))
    #expect(MarkdownAction.continuation(after: "9. nine") == .next("10. "))
    #expect(MarkdownAction.continuation(after: "- [x] done") == .next("- [ ] "))
    #expect(MarkdownAction.continuation(after: "  - ") == .end(markerLength: 4))
    #expect(MarkdownAction.continuation(after: "Plain text") == nil)
    #expect(MarkdownAction.continuation(after: "2026 was") == nil)
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

@Test func remindersComeFromTheNotesEvenForMeetingsNotOnScreen() {
    let later = Date.now.addingTimeInterval(30 * 86_400)   // weeks past what the calendar has loaded
    var far = Note(name: "far.md", text: "# Prep\n\nAgenda")
    far.link(to: CalendarEvent(id: "far", title: "Board meeting", start: later, end: later + 3600))
    var moved = Note(name: "moved.md", text: "# Sync")
    moved.link(to: CalendarEvent(id: "moved", title: "Old title", start: later, end: later + 3600))
    var dropped = Note(name: "dropped.md", text: "# Gone")
    dropped.link(to: CalendarEvent(id: "dropped", title: "Cancelled", start: later, end: later + 3600))
    let loaded = [CalendarEvent(id: "moved", title: "New title", start: later + 7200, end: later + 9000),
                  CalendarEvent(id: "dropped", title: "Cancelled", start: later, end: later + 3600, isCancelled: true)]
    let meetings = NoteReminders.meetings(for: [far, moved, dropped, Note(name: "loose.md", text: "# No meeting")], loaded: loaded)
        .sorted { $0.event.id < $1.event.id }
    #expect(meetings.map(\.event.id) == ["far", "moved"])
    #expect(meetings[0].event.title == "Board meeting" && meetings[0].event.start.timeIntervalSince(later) < 1)
    #expect(meetings[1].event.title == "New title" && meetings[1].event.start == later + 7200)
}

@Test func settingsNoteReadsBackWhatItWrote() throws {
    let settings = SharedSettings(showPrivate: false, privateCategories: ["Private", "Family"], privateListIDs: ["L2"],
                                  listOrder: ["L2", "L1"], firstWeekday: 2, firstHour: 8, lastHour: 19)
    let note = Note(name: settingsNoteName, text: settings.text(listNames: ["L1": "Work", "L2": "Home"]))
    #expect(note.isSettings && SharedSettings(note) == settings)
    #expect(note.body.contains("List order: Home, Work"))
    #expect(SharedSettings(Note(name: settingsNoteName, text: "# edited by hand")) == nil)
}

@Test func noteSearchForgivesTypos() {
    let notes = [
        Note(name: "a.md", text: "# Pricing meeting\n\nTiers for Q2."),
        Note(name: "b.md", text: "# Groceries\n\nMilk, eggs."),
    ]
    #expect(searchNotes(notes, "pricng").map(\.note.name) == ["a.md"])     // a letter missing
    #expect(searchNotes(notes, "meetnig").map(\.note.name) == ["a.md"])    // two swapped
    #expect(searchNotes(notes, "grocereis").map(\.note.name) == ["b.md"])
    #expect(searchNotes(notes, "eggz").map(\.note.name) == ["b.md"])
    #expect(searchNotes(notes, "xyz").isEmpty)                             // too short to guess at
    #expect(fuzzyMatch("meeting", "meet") > fuzzyMatch("meeting", "meet".replacingOccurrences(of: "t", with: "y")))
}

@Test func notePreviewsReadPlainAndCountToDos() {
    #expect(plainMarkdown("- [ ] **Call** [Ana](https://example.com) <u>now</u>") == "Call Ana now")
    #expect(plainMarkdown("  12. *one*") == "one")
    #expect(Note(name: "a.md", text: "# A\nplain").todoSummary == nil)
    #expect(Note(name: "a.md", text: "- [ ] a\n- [ ] b").todoSummary == "2 to-dos")
    #expect(Note(name: "a.md", text: "- [x] a\n  - [ ] b\n* [X] c").todoSummary == "2 of 3 done")
    #expect(Note(name: "a.md", text: "- [x] a\n- [X] b").todoSummary == "All 2 done")
    #expect(toggleTask(in: "x\n- [ ] a\n- [X] b", line: 1) == "x\n- [x] a\n- [X] b")
    #expect(toggleTask(in: "x\n- [ ] a\n- [X] b", line: 2) == "x\n- [ ] a\n- [ ] b")
    #expect(toggleTask(in: "x", line: 0) == "x")
}

@Test @MainActor func searchFindsMeetingsOnceAndPutsTheCurrentViewFirst() {
    let now = Date(timeIntervalSince1970: 1_800_000_000), day = 86_400.0
    func meeting(_ id: String, _ title: String, in days: Double, with attendees: [String] = []) -> CalendarEvent {
        var event = CalendarEvent(id: id, title: title, start: now + days * day, end: now + days * day + 3600)
        event.attendees = attendees
        return event
    }
    let events = [meeting("past", "Weekly sync", in: -7), meeting("next", "Weekly sync", in: 7), meeting("later", "Weekly sync", in: 14),
                  meeting("old", "Budget review", in: -30), meeting("older", "Budget review", in: -60),
                  meeting("ana", "Lunch", in: 1, with: ["Ana Example"])]
    #expect(searchEvents(events, "weekly", now: now).map(\.id) == ["next"])   // a repeating one once: the next
    #expect(searchEvents(events, "budgt", now: now).map(\.id) == ["old"])   // none ahead: the last; typos forgiven
    #expect(searchEvents(events, "ana", now: now).map(\.id) == ["ana"])
    #expect(searchEvents(events, "nothing", now: now).isEmpty)
    // Two meetings of one title: the one that matches is found, whichever is nearer.
    let talks = [meeting("bob", "1:1", in: 1, with: ["Bob Example"]), meeting("ana2", "1:1", in: 8, with: ["Ana Example"])]
    #expect(searchEvents(talks, "ana", now: now).map(\.id) == ["ana2"])
    #expect(SearchResults.Kind.ordered(first: .meetings) == [.meetings, .tasks, .notes])
    #expect(SearchResults.Kind.ordered(first: .tasks) == [.tasks, .notes, .meetings])
}

@Test func taskSearchFindsTitlesAndNotesAndGroupsDoneByDay() {
    let tasks = [
        TodoTask(id: "1", title: "Send pricing deck", listName: "Work"),
        TodoTask(id: "2", title: "Call Jonas", listName: "Personal", notes: "ask about the new price list"),
        TodoTask(id: "3", title: "Water plants", listName: "Errands"),
    ]
    #expect(searchTasks(tasks, "pric").map(\.id) == ["1", "2"])      // the title counts more than the note
    #expect(searchTasks(tasks, "plnts").map(\.id) == ["3"])          // a typo
    #expect(searchTasks(tasks, " ").isEmpty)
    let marked = highlighting("Send pricing deck", "pric")
    #expect(marked.runs.contains { $0.backgroundColor != nil && String(marked[$0.range].characters) == "pricing" })

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
    cal.firstWeekday = 7   // Saturday, as lães starts weeks
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 16))!   // a Friday
    func done(_ id: String, daysAgo: Int) -> TodoTask {
        TodoTask(id: id, title: id, listName: "L", completed: cal.date(byAdding: .day, value: -daysAgo, to: now))
    }
    let groups = completedGroups([done("old", daysAgo: 40), done("today", daysAgo: 0), done("yesterday", daysAgo: 1),
                                  done("week", daysAgo: 5), done("last", daysAgo: 8)], now: now, calendar: cal)
    #expect(groups.map(\.title) == ["Today", "Yesterday", "This Week", "Last Week", "October 2026"])
    #expect(groups.map { $0.tasks.map(\.id) } == [["today"], ["yesterday"], ["week"], ["last"], ["old"]])
}
