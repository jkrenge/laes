import Testing
import Foundation
@testable import Laes

@Test func weekStartsOnSaturday() {
    let cal = Calendar.laes
    let wed = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15))!
    let start = cal.weekStart(for: wed)
    #expect(cal.dateComponents([.year, .month, .day], from: start) == DateComponents(year: 2026, month: 11, day: 14))
    #expect(cal.weekStart(for: start) == start)
}

@Test func quickAddReadsDueDaysAndStars() {
    let cal = Calendar.laes
    let mon = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 15))!   // a Monday
    func day(_ d: Int, _ m: Int = 11) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d))! }

    let a = QuickAdd("Call mom today", now: mon)
    #expect(a.title == "Call mom" && a.due == day(23) && !a.isImportant)
    #expect(QuickAdd("Pay rent next month", now: mon).due == day(1, 12))
    #expect(QuickAdd("Review next week", now: mon).due == day(30))
    #expect(QuickAdd("Standup on Monday", now: mon).due == day(30))   // the next one, not today
    #expect(QuickAdd("Standup on Monday", now: mon).title == "Standup")
    let b = QuickAdd("tomorrow file taxes star", now: mon)
    #expect(b.title == "file taxes" && b.due == day(24) && b.isImportant)
    #expect(QuickAdd("Read today's paper", now: mon).due == nil)
    #expect(QuickAdd("Starting priorities", now: mon).isImportant == false)
    let c = QuickAdd("Plan Friday party", now: mon, ignoring: ["friday"])
    #expect(c.due == nil && c.title == "Plan Friday party")
}

@Test func everyIconDesignHasAnIPhoneIcon() {
    let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("LaesiOS/Assets.xcassets")
    // Every way to fill the corners by the rules, reached by placing stickers one at a time.
    var designs: Set<String> = [IconDesign(stickers: [:]).code], frontier = [IconDesign(stickers: [:])]
    while let design = frontier.popLast() {
        for sticker in Sticker.allCases where design.corner(of: sticker) == nil {
            for corner in sticker.corners where design.stickers[corner] == nil {
                var next = design
                next.place(sticker, at: corner)
                if designs.insert(next.code).inserted { frontier.append(next) }
            }
        }
    }
    #expect(designs.count == 143)
    for code in designs {
        let design = IconDesign(code: code)!
        #expect(design.code == code)
        let icon = catalog.appendingPathComponent("\(design.iconName ?? "AppIcon").appiconset/icon.png")
        #expect(FileManager.default.fileExists(atPath: icon.path), "no icon for \(code)")
    }
}

@Test func placingAStickerSwapsAndKeepsOneTilde() {
    var design = IconDesign.standard
    design.place(.page, at: .bottomLeft, from: .topRight)   // onto the tick: they swap
    #expect(design.stickers[.bottomLeft] == .page && design.stickers[.topRight] == .tick)
    design.place(.whiteTilde, at: .bottomRight)   // replaces the name and takes the yellow tilde away
    #expect(design.stickers[.bottomRight] == .whiteTilde && design.stickers[.topLeft] == nil)
    #expect(IconDesign(code: "ynl") == nil)   // a design saved before corners
}

@Test func aRedactedMeetingKeepsOnlyItsTime() {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var event = CalendarEvent(id: "e", title: "Doctor", start: start, end: start + 3600, location: "Clinic",
                              categories: ["Private"], response: .accepted, isPrivate: true, isOnlineMeeting: true,
                              webLink: URL(string: "https://outlook.office.com/e"), attendees: ["Dr. A"], joinURL: URL(string: "https://teams.microsoft.com/j"))
    event = event.redacted
    #expect(event.isRedacted && event.start == start && event.end == start + 3600 && event.response == .accepted)
    #expect(event.title.isEmpty && event.location == nil && event.categories.isEmpty && event.attendees.isEmpty)
    #expect(event.webLink == nil && event.joinURL == nil && !event.isOnlineMeeting && !event.isOwn)
}

@Test func meetingSearchMatchesTitlePlaceAndPeople() {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let event = CalendarEvent(id: "e", title: "1:1 Julian / Peter", start: start, end: start + 1800, location: "Café Müller",
                              attendees: ["Peter Schmidt", "Ana Lópes"])
    #expect(event.matches("") && event.matches("peter 1:1") && event.matches("cafe muller") && event.matches("ana lopes"))
    #expect(!event.matches("peter budget"))
}
