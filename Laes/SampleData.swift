import Foundation

/// Generic demo content shown while signed out, relative to the visible weeks.
enum SampleData {
    static let categoryColors: [String: String] = [
        "Team": "#3D3AD3",
        "Customer": "#0F8A5F",
        "Focus": "#E0A100",
        "Personal": "#D2465B",
    ]

    static func events(weekStart: Date) -> [CalendarEvent] {
        let cal = Calendar.laes
        let link = URL(string: "https://outlook.office.com/calendar/")
        var count = 0

        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: weekStart)! }

        func event(_ dayOffset: Int, _ hour: Double, _ minutes: Int, _ title: String, _ category: String,
                   location: String? = nil, _ configure: (inout CalendarEvent) -> Void = { _ in }) -> CalendarEvent {
            count += 1
            let start = cal.date(byAdding: .minute, value: Int(hour * 60), to: day(dayOffset))!
            var e = CalendarEvent(id: "sample-\(count)", title: title, start: start,
                                  end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                  location: location, categories: [category], webLink: link)
            configure(&e)
            return e
        }

        func allDay(_ dayOffset: Int, days: Int, _ title: String, _ category: String) -> CalendarEvent {
            count += 1
            return CalendarEvent(id: "sample-\(count)", title: title, start: day(dayOffset), end: day(dayOffset + days),
                                 isAllDay: true, categories: [category], showAs: .free, webLink: link)
        }

        let online: (inout CalendarEvent) -> Void = { $0.isOnlineMeeting = true }
        let series: (inout CalendarEvent) -> Void = { $0.isRecurring = true; $0.isOnlineMeeting = true }

        return [
            // Week 1 (Sat = 0, Mon = 2 … Fri = 6)
            event(2, 9, 30, "Weekly sync", "Team", location: "Teams", series),
            event(2, 10, 90, "Budget review", "Customer", location: "Room 2.14"),
            event(2, 10.5, 45, "Vendor call", "Customer", online),
            event(2, 14, 120, "Focus time", "Focus") { $0.showAs = .free },
            event(3, 8.5, 15, "Daily standup", "Team", series),
            event(3, 11, 60, "Design critique", "Team", location: "Studio") { $0.showAs = .tentative; $0.response = .tentativelyAccepted },
            event(3, 12.5, 60, "Doctor appointment", "Personal") { $0.isPrivate = true; $0.showAs = .oof },
            event(3, 15, 90, "Quarterly planning", "Team", location: "Room 3.02"),
            event(3, 15.5, 60, "Hiring sync", "Team", online),
            event(4, 8.5, 15, "Daily standup", "Team", series),
            event(4, 12, 60, "Product demo", "Customer", location: "Auditorium"),
            event(4, 16, 60, "Roadmap Q&A", "Team") { $0.response = .declined; $0.isOnlineMeeting = true },
            allDay(4, days: 1, "Release day", "Team"),
            event(5, 9, 60, "Onboarding session", "Team", location: "Room 1.08"),
            event(5, 14, 60, "Partner check-in", "Customer") { $0.isCancelled = true },
            event(5, 21, 60, "Release window", "Team"),
            event(6, 9.5, 30, "Team retro", "Team", series),
            event(6, 11, 90, "Pricing workshop", "Customer", location: "Room 2.14"),
            // Week 2
            event(9, 9, 30, "Weekly sync", "Team", location: "Teams", series),
            event(9, 10, 60, "Strategy review", "Customer", location: "Board room"),
            event(9, 10.5, 60, "Contract walkthrough", "Customer", online),
            event(9, 10.75, 75, "Analytics deep dive", "Focus"),
            event(10, 8.5, 15, "Daily standup", "Team", series),
            event(10, 13, 45, "1:1 coaching", "Personal", location: "Café") { $0.isPrivate = true },
            event(11, 8.5, 15, "Daily standup", "Team", series),
            event(11, 14, 120, "Board prep", "Focus"),
            event(12, 6, 45, "Early train to offsite", "Personal"),
            allDay(12, days: 2, "Team offsite", "Team"),
            event(13, 9.5, 30, "Team retro", "Team", series),
            event(13, 15, 60, "Offsite wrap-up", "Team", location: "Lakeside hall"),
        ]
    }

    static func tasks(weekStart: Date) -> [TodoTask] {
        func day(_ offset: Int) -> Date { Calendar.laes.date(byAdding: .day, value: offset, to: weekStart)! }
        return [
            TodoTask(id: "task-1", title: "Send meeting notes", listName: "Work", due: day(-3)),
            TodoTask(id: "task-2", title: "Review budget draft", listName: "Work", due: day(2), isImportant: true),
            TodoTask(id: "task-3", title: "Book meeting room", listName: "Work", due: day(2)),
            TodoTask(id: "task-4", title: "Update project plan", listName: "Work", due: day(3)),
            TodoTask(id: "task-5", title: "Reply to team survey", listName: "Work", due: day(4)),
            TodoTask(id: "task-6", title: "Prepare demo script", listName: "Work", due: day(4)),
            TodoTask(id: "task-7", title: "Renew parking permit", listName: "Personal", due: day(5)),
            TodoTask(id: "task-8", title: "Submit expense report", listName: "Work", due: day(6), isImportant: true),
            TodoTask(id: "task-9", title: "Draft offsite agenda", listName: "Work", due: day(9)),
            TodoTask(id: "task-10", title: "Order team lunch", listName: "Work", due: day(11)),
            TodoTask(id: "task-11", title: "Read onboarding guide", listName: "Personal"),
        ]
    }

    /// Done ones, for the Completed view: hours and days before `now`.
    static func completedTasks(now: Date) -> [TodoTask] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        return [
            TodoTask(id: "done-1", title: "Book flights for the offsite", listName: "Personal", completed: ago(1)),
            TodoTask(id: "done-2", title: "Reply to the team survey reminder", listName: "Work", completed: ago(3)),
            TodoTask(id: "done-3", title: "Draft budget questions", listName: "Work", completed: ago(26)),
            TodoTask(id: "done-4", title: "Pick up parcel", listName: "Personal", completed: ago(30)),
            TodoTask(id: "done-5", title: "Review last quarter's project plan", listName: "Work", completed: ago(80)),
            TodoTask(id: "done-6", title: "Send meeting room feedback", listName: "Work", completed: ago(200)),
        ]
    }
}
