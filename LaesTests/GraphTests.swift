import Testing
import Foundation
@testable import Laes

@MainActor
struct GraphTests {
    let cal = Calendar.laes

    @Test func pkceMatchesRFC7636Vector() {
        #expect(AuthService.pkceChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func decodesCalendarView() throws {
        let json = """
        {
          "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users('me')/calendarView",
          "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/calendarView?$skip=100",
          "value": [
            {
              "@odata.etag": "W/\\"abc\\"",
              "id": "AAMk-timed",
              "subject": "Design review",
              "start": { "dateTime": "2026-11-18T09:30:00.0000000", "timeZone": "UTC" },
              "end": { "dateTime": "2026-11-18T10:15:00.0000000", "timeZone": "UTC" },
              "isAllDay": false,
              "location": { "displayName": "Room 4.12", "locationType": "default" },
              "categories": ["Blue category"],
              "showAs": "busy",
              "responseStatus": { "response": "accepted", "time": "2026-11-10T08:00:00Z" },
              "sensitivity": "normal",
              "type": "singleInstance",
              "isOnlineMeeting": true,
              "isCancelled": false,
              "webLink": "https://outlook.office365.com/owa/?itemid=AAMk-timed&exvsurl=1&path=/calendar/item"
            },
            {
              "id": "AAMk-allday",
              "subject": "  ",
              "start": { "dateTime": "2026-11-20T00:00:00.0000000", "timeZone": "UTC" },
              "end": { "dateTime": "2026-11-22T00:00:00.0000000", "timeZone": "UTC" },
              "isAllDay": true,
              "location": { "displayName": "" },
              "categories": [],
              "showAs": "oof",
              "responseStatus": { "response": "organizer", "time": "0001-01-01T00:00:00Z" },
              "sensitivity": "normal",
              "type": "singleInstance",
              "isOnlineMeeting": false,
              "isCancelled": false,
              "webLink": null
            },
            {
              "id": "AAMk-private",
              "subject": "Doctor",
              "start": { "dateTime": "2026-11-19T14:00:00.0000000", "timeZone": "UTC" },
              "end": { "dateTime": "2026-11-19T15:00:00.0000000", "timeZone": "UTC" },
              "isAllDay": false,
              "location": null,
              "categories": ["Personal", "Health"],
              "showAs": "tentative",
              "responseStatus": { "response": "tentativelyAccepted", "time": "2026-11-01T08:00:00Z" },
              "sensitivity": "private",
              "type": "occurrence",
              "isOnlineMeeting": false,
              "isCancelled": false,
              "webLink": "https://outlook.office365.com/owa/?itemid=AAMk-private"
            }
          ]
        }
        """
        let page = try GraphClient.decodeEvents(Data(json.utf8))
        #expect(page.next?.absoluteString == "https://graph.microsoft.com/v1.0/me/calendarView?$skip=100")
        #expect(page.items.count == 3)

        let timed = page.items[0]
        #expect(timed.title == "Design review")
        #expect(timed.start == Date(timeIntervalSince1970: 1_794_994_200))  // 2026-11-18T09:30:00Z
        #expect(timed.end.timeIntervalSince(timed.start) == 45 * 60)
        #expect(!timed.isAllDay)
        #expect(timed.location == "Room 4.12")
        #expect(timed.categories == ["Blue category"])
        #expect(timed.showAs == .busy)
        #expect(timed.response == .accepted)
        #expect(!timed.isPrivate && !timed.isRecurring && timed.isOnlineMeeting && !timed.isCancelled)
        #expect(timed.webLink != nil)

        let allDay = page.items[1]
        #expect(allDay.title == "(No title)")
        #expect(allDay.isAllDay)
        #expect(allDay.start == cal.date(from: DateComponents(year: 2026, month: 11, day: 20)))
        #expect(allDay.end == cal.date(from: DateComponents(year: 2026, month: 11, day: 22)))
        #expect(allDay.location == nil)
        #expect(allDay.showAs == .oof)
        #expect(allDay.response == .organizer)
        #expect(allDay.webLink == nil)

        let priv = page.items[2]
        #expect(priv.isPrivate)
        #expect(priv.isRecurring)
        #expect(priv.showAs == .tentative)
        #expect(priv.response == .tentativelyAccepted)
        #expect(priv.location == nil)
        #expect(priv.categories == ["Personal", "Health"])
    }

    @Test func decodesAttendeesJoinLinkAndOwnCategory() throws {
        let json = """
        {"value":[{"id":"e1","subject":"Focus","start":{"dateTime":"2026-11-23T09:00:00.0000000"},"end":{"dateTime":"2026-11-23T10:00:00.0000000"},
          "categories":["lães"],"attendees":[{"emailAddress":{"name":"Ada","address":"ada@example.com"}},{"emailAddress":{"address":"bob@example.com"}}],
          "onlineMeeting":{"joinUrl":"https://example.com/join"}}]}
        """
        let event = try #require(try GraphClient.decodeEvents(Data(json.utf8)).items.first)
        #expect(event.attendees == ["Ada", "bob@example.com"])
        #expect(event.joinURL?.absoluteString == "https://example.com/join")
        #expect(event.isOwn)
    }

    @Test func decodesTodoTasks() throws {
        let json = """
        {
          "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users('me')/todo/lists('x')/tasks",
          "value": [
            {
              "@odata.etag": "W/\\"t1\\"",
              "importance": "high",
              "isReminderOn": false,
              "status": "notStarted",
              "title": "Send Q4 numbers",
              "createdDateTime": "2026-11-10T08:00:00.0000000Z",
              "id": "task-1",
              "body": { "content": "", "contentType": "text" },
              "dueDateTime": { "dateTime": "2026-11-21T00:00:00.0000000", "timeZone": "UTC" }
            },
            {
              "importance": "normal",
              "status": "inProgress",
              "title": "Book flights",
              "id": "task-2"
            }
          ]
        }
        """
        let page = try GraphClient.decodeTasks(Data(json.utf8), list: TaskList(id: "list-1", name: "Work"))
        #expect(page.next == nil)
        #expect(page.items.count == 2)
        let first = page.items[0]
        #expect(first.id == "task-1")
        #expect(first.title == "Send Q4 numbers")
        #expect(first.listName == "Work")
        #expect(first.listID == "list-1")
        #expect(first.isImportant)
        #expect(first.due == cal.date(from: DateComponents(year: 2026, month: 11, day: 21)))
        #expect(page.items[1].due == nil)
        #expect(!page.items[1].isImportant)
    }

    @Test func dueDaySnapsToNearestLocalMidnight() {
        for zone in ["America/New_York", "Europe/Berlin"] {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: zone)!
            let nov21 = cal.date(from: DateComponents(year: 2026, month: 11, day: 21))
            // midnight 21 Nov in Berlin, in New York, and plain UTC
            for stored in ["2026-11-20T23:00:00.0000000", "2026-11-21T05:00:00.0000000", "2026-11-21T00:00:00.0000000"] {
                #expect(GraphClient.dueDay(stored, calendar: cal) == nov21, "\(stored) in \(zone)")
            }
        }
    }

    @Test func readsAndWritesRepeatsAndReminders() throws {
        let json = """
        { "value": [
          { "id": "a", "title": "Weekdays", "isReminderOn": true, "reminderDateTime": { "dateTime": "2026-11-23T08:00:00.0000000", "timeZone": "UTC" },
            "recurrence": { "pattern": { "type": "weekly", "interval": 1, "daysOfWeek": ["monday", "tuesday", "wednesday", "thursday", "friday"] } } },
          { "id": "b", "title": "Off", "isReminderOn": false, "reminderDateTime": { "dateTime": "2026-11-23T08:00:00.0000000", "timeZone": "UTC" },
            "recurrence": { "pattern": { "type": "weekly", "interval": 2, "daysOfWeek": ["monday"] } } }
        ] }
        """
        let tasks = try GraphClient.decodeTasks(Data(json.utf8), list: TaskList(id: "l", name: "L")).items
        #expect(tasks[0].repeats == RepeatRule(unit: .weekdays))
        #expect(tasks[0].recurrence == "Repeats on weekdays")
        #expect(tasks[0].reminder == GraphClient.utcDate("2026-11-23T08:00:00"))
        #expect(tasks[1].repeats == RepeatRule(unit: .weekly, interval: 2))
        #expect(tasks[1].reminder == nil)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let wednesday = cal.date(from: DateComponents(year: 2026, month: 11, day: 25))!
        let weekly = GraphClient.recurrenceBody(RepeatRule(unit: .weekly, interval: 2), due: wednesday, calendar: cal)
        let pattern = try #require(weekly["pattern"] as? [String: Any])
        #expect(pattern["type"] as? String == "weekly")
        #expect(pattern["interval"] as? Int == 2)
        #expect(pattern["daysOfWeek"] as? [String] == ["wednesday"])
        #expect((weekly["range"] as? [String: String])?["startDate"] == "2026-11-25")
        let yearly = try #require(GraphClient.recurrenceBody(RepeatRule(unit: .yearly), due: wednesday, calendar: cal)["pattern"] as? [String: Any])
        #expect(yearly["type"] as? String == "absoluteYearly")
        #expect(yearly["dayOfMonth"] as? Int == 25)
        #expect(yearly["month"] as? Int == 11)
        // Read back, each written rule is the same rule.
        for unit in RepeatRule.Unit.allCases {
            let p = try #require(GraphClient.recurrenceBody(RepeatRule(unit: unit), due: wednesday, calendar: cal)["pattern"] as? [String: Any])
            #expect(GraphClient.repeatRule(type: p["type"] as! String, interval: p["interval"] as! Int, days: p["daysOfWeek"] as? [String] ?? []) == RepeatRule(unit: unit))
        }
    }

    @Test func decodesNotesRecurrenceAndChecklist() throws {
        let json = """
        { "value": [
          { "id": "a", "title": "Daily", "body": { "content": "call back\\r\\n", "contentType": "text" },
            "recurrence": { "pattern": { "type": "daily", "interval": 1 } } },
          { "id": "b", "title": "Formatted",
            "body": { "content": "<html><head><style>p{}</style></head><body><p>Tom &amp; Ann</p><div>line 2<br></div></body></html>", "contentType": "html" },
            "recurrence": { "pattern": { "type": "absoluteMonthly", "interval": 3 } } },
          { "id": "c", "title": "Empty shell", "body": { "content": "<html><body></body></html>", "contentType": "html" } }
        ] }
        """
        let tasks = try GraphClient.decodeTasks(Data(json.utf8), list: TaskList(id: "l", name: "L")).items
        #expect(tasks[0].notes == "call back")
        #expect(!tasks[0].notesReadOnly)
        #expect(tasks[0].recurrence == "Repeats daily")
        #expect(tasks[1].notes == "Tom & Ann\nline 2")
        #expect(tasks[1].notesReadOnly)
        #expect(tasks[1].recurrence == "Repeats every 3 months")
        #expect(tasks[2].notes.isEmpty)
        #expect(!tasks[2].notesReadOnly)
        #expect(tasks[2].recurrence == nil)

        #expect(tasks[2].reminder == nil)
        #expect(tasks[2].repeats == nil)
        let steps = try GraphClient.decodeChecklist(Data(#"{"value":[{"id":"s1","displayName":"UPS","isChecked":true},{"id":"s2","displayName":"URBN"}]}"#.utf8)).items
        #expect(steps == [ChecklistItem(id: "s1", title: "UPS", isChecked: true), ChecklistItem(id: "s2", title: "URBN")])
    }

    @Test func privateCategoryMatchIgnoresCase() {
        #expect(hasCategory(["Team", "privat"], in: ["Privat", "Private"]))
        #expect(!hasCategory(["Team"], in: ["Privat", "Private"]))
        #expect(!hasCategory([], in: ["Privat"]))
    }

    @Test func decodesCategoryColors() throws {
        let json = #"{"value":[{"id":"1","displayName":"Red category","color":"preset0"},{"id":"2","displayName":"Plain","color":"none"}]}"#
        let colors = try GraphClient.decodeCategoryColors(Data(json.utf8))
        #expect(colors["Red category"] == GraphClient.presetColors["preset0"])
        #expect(colors["Plain"] != nil)
    }
}
