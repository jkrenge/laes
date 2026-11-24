import Foundation
import Testing
@testable import Laes

private let cal = Calendar.laes
private let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 18))!

private func event(_ id: String, _ startHour: Double, _ endHour: Double) -> CalendarEvent {
    CalendarEvent(id: id, title: id, start: base.addingTimeInterval(startHour * 3600), end: base.addingTimeInterval(endHour * 3600))
}

private func columns(_ events: [CalendarEvent]) -> [String: (Int, Int)] {
    Dictionary(uniqueKeysWithValues: layoutEvents(events).map { ($0.event.id, ($0.column, $0.columnCount)) })
}

@Test func nonOverlappingEventsGetOneColumnEach() {
    let c = columns([event("a", 9, 10), event("b", 10, 11), event("c", 13, 14)])
    #expect(c.values.allSatisfy { $0 == (0, 1) })
}

@Test func threeMutuallyOverlappingEventsGetThreeColumns() {
    let c = columns([event("a", 9, 12), event("b", 9.5, 11), event("c", 10, 10.5)])
    #expect(c["a"]! == (0, 3))
    #expect(c["b"]! == (1, 3))
    #expect(c["c"]! == (2, 3))
}

@Test func chainedOverlapReusesFreedColumn() {
    // A overlaps B, B overlaps C, A and C do not.
    let c = columns([event("c", 10.5, 11.5), event("a", 9, 10), event("b", 9.5, 11)])
    #expect(c["a"]! == (0, 2))
    #expect(c["b"]! == (1, 2))
    #expect(c["c"]! == (0, 2))
}

@Test func tasksBucketByDueDayAndOverdueMovesToToday() {
    let today = base.addingTimeInterval(15 * 3600)
    let yesterday = cal.date(byAdding: .day, value: -1, to: base)!
    let tomorrow = cal.date(byAdding: .day, value: 1, to: base)!
    let tasks = [
        TodoTask(id: "overdue", title: "Overdue", listName: "L", due: cal.date(byAdding: .day, value: -5, to: base)),
        TodoTask(id: "today", title: "Today", listName: "L", due: base),
        TodoTask(id: "tomorrow", title: "Tomorrow", listName: "L", due: tomorrow),
        TodoTask(id: "yesterday", title: "Yesterday", listName: "L", due: yesterday),
        TodoTask(id: "none", title: "No date", listName: "L"),
    ]
    #expect(tasksDue(on: base, from: tasks, today: today).map(\.id) == ["overdue", "yesterday", "today"])
    #expect(tasksDue(on: tomorrow, from: tasks, today: today).map(\.id) == ["tomorrow"])
    #expect(tasksDue(on: yesterday, from: tasks, today: today).isEmpty)
}

@Test func multiDayAllDayBarIsClippedToWeek() {
    let weekStart = cal.weekStart(for: base)   // Sat 14 Nov
    let offsite = CalendarEvent(id: "o", title: "Offsite", start: cal.date(byAdding: .day, value: 5, to: weekStart)!,
                                end: cal.date(byAdding: .day, value: 9, to: weekStart)!, isAllDay: true)
    let bar = allDayBars([offsite], weekStart: weekStart).first!
    #expect((bar.startColumn, bar.endColumn, bar.lane) == (5, 7, 0))
}

@Test func plannedFiltersSplitByDueDay() {
    // Monday 23 Nov 2026; weeks start on Saturday, so this week ends before Saturday 28.
    let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 23))!
    let day = { cal.date(byAdding: .day, value: $0, to: today)! }
    func matches(_ offset: Int) -> [PlannedFilter] { PlannedFilter.allCases.filter { $0.contains(day(offset), today: today, calendar: cal) } }
    #expect(matches(-1) == [.all, .overdue, .dueNow])
    #expect(matches(0) == [.all, .dueNow, .today, .week])
    #expect(matches(1) == [.all, .tomorrow, .week])
    #expect(matches(4) == [.all, .week])
    #expect(matches(5) == [.all, .later])
}

@Test func quickDueDaysAreTheComingMondayAndSaturday() {
    let date = { cal.date(from: DateComponents(year: 2026, month: 11, day: $0))! }
    func days(from day: Int) -> [Date] { QuickDue.allCases.map { $0.day(from: date(day).addingTimeInterval(15 * 3600), calendar: cal) } }
    #expect(days(from: 22) == [date(22), date(23), date(23), date(28)])   // Sunday
    #expect(days(from: 28) == [date(28), date(29), date(30), cal.date(byAdding: .day, value: 7, to: date(28))!])   // Saturday: the weekend after
}

@Test func aTaskAddedUnderAFilterShowsInIt() {
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 15))!
    for filter in PlannedFilter.allCases where filter != .overdue {   // nothing new can be overdue
        #expect(filter.contains(filter.newTaskDay(today: now, calendar: cal), today: now, calendar: cal), "\(filter)")
    }
}

@Test func listsFollowTheSavedOrderWithNewOnesLast() {
    let lists = ["a", "b", "c", "d"].map { TaskList(id: $0, name: $0) }
    #expect(ordered(lists, by: ["c", "gone", "a"]).map(\.id) == ["c", "a", "b", "d"])
    #expect(ordered(lists, by: []).map(\.id) == ["a", "b", "c", "d"])
}
