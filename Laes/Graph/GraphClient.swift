import Foundation

struct GraphClient {
    let auth: AuthService
    private static let base = "https://graph.microsoft.com/v1.0"

    private static let eventFields = "id,subject,start,end,isAllDay,location,categories,showAs,responseStatus,sensitivity,type,isOnlineMeeting,isCancelled,webLink,attendees,onlineMeeting"

    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        var components = URLComponents(string: Self.base + "/me/calendarView")!
        components.queryItems = [
            .init(name: "startDateTime", value: from.ISO8601Format()),
            .init(name: "endDateTime", value: to.ISO8601Format()),
            .init(name: "$top", value: "100"),
            .init(name: "$select", value: Self.eventFields),
        ]
        return try await paged(components.url!, Self.decodeEvents)
    }

    /// One event with its description (as plain text) and organizer.
    func eventDetails(id: String) async throws -> (event: CalendarEvent, description: String, organizer: String?) {
        struct Extra: Decodable {
            struct Body: Decodable { var content: String? }
            struct Organizer: Decodable { struct Address: Decodable { var name: String?; var address: String? }; var emailAddress: Address? }
            var body: Body?
            var organizer: Organizer?
        }
        var components = URLComponents(url: eventURL(CalendarEvent(id: id, title: "", start: .now, end: .now)), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "$select", value: Self.eventFields + ",body,organizer")]
        let data = try await send(components.url!)
        guard let event = try Self.decodeEvents(Data("{\"value\":[".utf8) + data + Data("]}".utf8)).items.first else {
            throw GraphError("Microsoft returned no meeting.")
        }
        let extra = try JSONDecoder().decode(Extra.self, from: data)
        return (event, Self.plainText(fromHTML: extra.body?.content ?? ""), extra.organizer?.emailAddress?.name ?? extra.organizer?.emailAddress?.address)
    }

    /// A private, busy meeting in the lães category.
    func createEvent(title: String, start: Date, end: Date) async throws -> CalendarEvent {
        let data = try await write(URL(string: Self.base + "/me/events")!, "POST", [
            "subject": title, "start": Self.timeBody(start), "end": Self.timeBody(end),
            "categories": [ownCategory], "sensitivity": "private", "showAs": "busy",
        ])
        guard let event = try Self.decodeEvents(Data("{\"value\":[".utf8) + data + Data("]}".utf8)).items.first else {
            throw GraphError("Microsoft returned no meeting.")
        }
        return event
    }

    func setEnd(_ event: CalendarEvent, to end: Date) async throws {
        try await write(eventURL(event), "PATCH", ["end": Self.timeBody(end)])
    }

    /// Moves the meeting to Outlook's Deleted Items.
    func deleteEvent(_ event: CalendarEvent) async throws {
        _ = try await send(eventURL(event), method: "DELETE")
    }

    private func eventURL(_ event: CalendarEvent) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_="))
        return URL(string: Self.base + "/me/events/" + event.id.addingPercentEncoding(withAllowedCharacters: allowed)!)!
    }

    private static func timeBody(_ date: Date) -> [String: String] {
        ["dateTime": String(date.ISO8601Format().dropLast()), "timeZone": "UTC"]
    }

    /// All To Do lists, and the open (not completed) tasks across them.
    func tasks() async throws -> (lists: [TaskList], tasks: [TodoTask]) {
        let lists = try await paged(URL(string: Self.base + "/me/todo/lists")!, Self.decodeLists)
        // One list at a time: Outlook allows an app 4 concurrent requests per mailbox, and a request
        // per list in parallel gets the whole sync throttled.
        var tasks: [TodoTask] = []
        for list in lists {
            var components = URLComponents(string: Self.base + "/me/todo/lists")!
            components.path += "/\(list.id)/tasks"
            components.queryItems = [
                .init(name: "$filter", value: "status ne 'completed'"),
                .init(name: "$top", value: "100"),
            ]
            tasks += try await paged(components.url!) { try Self.decodeTasks($0, list: list) }
        }
        return (lists, tasks)
    }

    /// Tasks completed since `since`, across `lists`, newest first. Asked for on demand, not with every sync.
    func completedTasks(in lists: [TaskList], since: Date) async throws -> [TodoTask] {
        var tasks: [TodoTask] = []
        for list in lists {   // one at a time, as in `tasks()`
            func url(_ filter: String) -> URL {
                var components = URLComponents(string: Self.base + "/me/todo/lists")!
                components.path += "/\(list.id)/tasks"
                components.queryItems = [.init(name: "$filter", value: filter), .init(name: "$top", value: "100")]
                return components.url!
            }
            let day = String(since.ISO8601Format().dropLast())   // UTC, as Graph writes completedDateTime
            do {
                tasks += try await paged(url("status eq 'completed' and completedDateTime/dateTime ge '\(day)'")) { try Self.decodeTasks($0, list: list) }
            } catch let error as GraphError where error.status == 400 {
                // shortcut: if To Do won't filter by completion date, take all completed tasks and filter here.
                tasks += try await paged(url("status eq 'completed'")) { try Self.decodeTasks($0, list: list) }
            }
        }
        return tasks.filter { ($0.completed ?? .distantPast) >= since }.sorted { $0.completed! > $1.completed! }
    }

    // MARK: Notes (Markdown files in the app's own OneDrive folder, which Microsoft creates on first use)

    struct NoteFile {
        var name: String
        var tag: String
        var modified: Date
        var download: URL?   // short-lived, needs no sign-in
    }

    private struct DriveItem: Decodable {
        var name: String
        var eTag: String?
        var lastModifiedDateTime: String?
        var download: URL?
        enum CodingKeys: String, CodingKey { case name, eTag, lastModifiedDateTime, download = "@microsoft.graph.downloadUrl" }

        var file: NoteFile {
            let modified = lastModifiedDateTime.flatMap { (try? Date($0, strategy: .iso8601)) ?? (try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) }
            return NoteFile(name: name, tag: eTag ?? "", modified: modified ?? .now, download: download)
        }
    }

    private static let notesFolder = base + "/me/drive/special/approot"

    func noteFiles() async throws -> [NoteFile] {
        try await paged(URL(string: Self.notesFolder + "/children?$top=200")!) { data in
            let page = try JSONDecoder().decode(OData<DriveItem>.self, from: data)
            return Page(items: page.value.filter { $0.name.hasSuffix(".md") }.map(\.file), next: page.next)
        }
    }

    func noteText(_ file: NoteFile) async throws -> String {
        guard let url = file.download else { throw GraphError("OneDrive gave no download link for \(file.name).") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GraphError("\(file.name) couldn't be downloaded from OneDrive.") }
        return String(decoding: data, as: UTF8.self)
    }

    /// Creates or replaces the file.
    func saveNote(name: String, text: String) async throws -> NoteFile {
        let data = try await send(noteURL(name, ":/content"), method: "PUT", body: Data(text.utf8), contentType: "text/markdown")
        return try JSONDecoder().decode(DriveItem.self, from: data).file
    }

    func deleteNote(name: String) async throws {
        _ = try await send(noteURL(name), method: "DELETE")
    }

    private func noteURL(_ name: String, _ suffix: String = "") -> URL {
        var components = URLComponents(string: Self.notesFolder)!
        components.path += ":/\(name)" + suffix
        return components.url!
    }

    func createList(name: String) async throws -> TaskList {
        let data = try await write(URL(string: Self.base + "/me/todo/lists")!, "POST", ["displayName": name])
        let list = try JSONDecoder().decode(GraphList.self, from: data)
        return TaskList(id: list.id, name: list.displayName)
    }

    func renameList(_ list: TaskList, to name: String) async throws {
        try await write(listURL(list), "PATCH", ["displayName": name])
    }

    /// Deletes the list and every task on it.
    func deleteList(_ list: TaskList) async throws {
        _ = try await send(listURL(list), method: "DELETE")
    }

    private func listURL(_ list: TaskList) -> URL {
        var components = URLComponents(string: Self.base + "/me/todo/lists")!
        components.path += "/\(list.id)"
        return components.url!
    }

    func createTask(title: String, due day: Date?, in list: TaskList) async throws -> TodoTask {
        let probe = TodoTask(id: "", title: title, listName: list.name, listID: list.id)
        let data = try await write(taskURL(probe), "POST", day.map { ["title": title, "dueDateTime": Self.dueBody($0)] } ?? ["title": title])
        return try JSONDecoder().decode(GraphTask.self, from: data).todo(in: list)
    }

    /// To Do can't move a task between lists, so it is copied into `list` with its note, steps, links and files, then deleted.
    func moveTask(_ task: TodoTask, to list: TaskList) async throws -> TodoTask {
        let source = try JSONSerialization.jsonObject(with: await send(taskURL(task))) as? [String: Any] ?? [:]
        let kept = ["title", "body", "importance", "categories", "dueDateTime", "startDateTime", "isReminderOn", "reminderDateTime"]
        var body = source.filter { kept.contains($0.key) && !($0.value is NSNull) }
        if let rule = task.repeats, let due = task.due { body["recurrence"] = Self.recurrenceBody(rule, due: due) }
        let links = try JSONSerialization.jsonObject(with: await send(taskURL(task, "/linkedResources"))) as? [String: Any]
        let linked = (links?["value"] as? [[String: Any]] ?? []).map { $0.filter { $0.key != "id" && !$0.key.hasPrefix("@") } }
        if !linked.isEmpty { body["linkedResources"] = linked }
        let steps = try await checklist(of: task)

        let probe = TodoTask(id: "", title: task.title, listName: list.name, listID: list.id)
        let moved = try JSONDecoder().decode(GraphTask.self, from: await write(taskURL(probe), "POST", body)).todo(in: list)
        do {
            for step in steps {
                try await write(taskURL(moved, "/checklistItems"), "POST", ["displayName": step.title, "isChecked": step.isChecked])
            }
            if source["hasAttachments"] as? Bool == true { try await copyAttachments(from: task, to: moved) }
        } catch {
            _ = try? await send(taskURL(moved), method: "DELETE")   // no half-copied duplicate; the task stays where it was
            throw error
        }
        _ = try await send(taskURL(task), method: "DELETE")
        return moved
    }

    /// A task's attached files onto another task: small ones in one request, larger ones (To Do takes up to 25 MB)
    /// through an upload session, in pieces.
    private func copyAttachments(from task: TodoTask, to target: TodoTask) async throws {
        struct File: Decodable { var id: String; var name: String; var contentType: String? }
        struct Files: Decodable { var value: [File] }
        for file in try JSONDecoder().decode(Files.self, from: await send(taskURL(task, "/attachments"))).value {
            let bytes = try await send(taskURL(task, "/attachments/\(file.id)/$value"))
            if bytes.count < 3_000_000 {
                try await write(taskURL(target, "/attachments"), "POST", [
                    "@odata.type": "#microsoft.graph.taskFileAttachment", "name": file.name,
                    "contentType": file.contentType ?? "application/octet-stream", "contentBytes": bytes.base64EncodedString(),
                ])
                continue
            }
            let session = try JSONSerialization.jsonObject(with: await write(taskURL(target, "/attachments/createUploadSession"), "POST",
                ["attachmentInfo": ["attachmentType": "file", "name": file.name, "size": bytes.count]])) as? [String: Any]
            guard let upload = (session?["uploadUrl"] as? String).flatMap(URL.init(string:)) else {
                throw GraphError("Microsoft didn't take the file “\(file.name)”.")
            }
            var start = 0
            while start < bytes.count {
                let end = min(start + 3_276_800, bytes.count)
                var request = URLRequest(url: upload)   // signed already: no Authorization header
                request.httpMethod = "PUT"
                request.setValue("bytes \(start)-\(end - 1)/\(bytes.count)", forHTTPHeaderField: "Content-Range")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (_, response) = try await URLSession.shared.upload(for: request, from: bytes[start..<end])
                guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                    throw GraphError("Couldn't copy the file “\(file.name)”.")
                }
                start = end
            }
        }
    }

    func completeTask(_ task: TodoTask) async throws {
        try await write(taskURL(task), "PATCH", ["status": "completed"])
    }

    func reopenTask(_ task: TodoTask) async throws {
        try await write(taskURL(task), "PATCH", ["status": "notStarted"])
    }

    /// `day` is a local midnight; To Do stores a due day as that instant in UTC.
    func setDue(_ task: TodoTask, day: Date?) async throws {
        try await write(taskURL(task), "PATCH", ["dueDateTime": day.map { Self.dueBody($0) as Any } ?? NSNull()])
    }

    func setTitle(_ task: TodoTask, _ title: String) async throws {
        try await write(taskURL(task), "PATCH", ["title": title])
    }

    func setImportant(_ task: TodoTask, _ important: Bool) async throws {
        try await write(taskURL(task), "PATCH", ["importance": important ? "high" : "normal"])
    }

    func setReminder(_ task: TodoTask, _ date: Date?) async throws {
        try await write(taskURL(task), "PATCH", date.map { ["isReminderOn": true, "reminderDateTime": Self.timeBody($0)] as [String: Any] } ?? ["isReminderOn": false])
    }

    /// A repeat needs a due date, so both go together; nil stops the task repeating.
    func setRepeat(_ task: TodoTask, _ rule: RepeatRule?, due: Date) async throws {
        try await write(taskURL(task), "PATCH", ["dueDateTime": Self.dueBody(due), "recurrence": rule.map { Self.recurrenceBody($0, due: due) as Any } ?? NSNull()])
    }

    func setNotes(_ task: TodoTask, _ text: String) async throws {
        try await write(taskURL(task), "PATCH", ["body": ["content": text, "contentType": "text"]])
    }

    func checklist(of task: TodoTask) async throws -> [ChecklistItem] {
        try await paged(taskURL(task, "/checklistItems"), Self.decodeChecklist)
    }

    func setChecked(_ item: ChecklistItem, _ checked: Bool, in task: TodoTask) async throws {
        try await write(taskURL(task, "/checklistItems/\(item.id)"), "PATCH", ["isChecked": checked])
    }

    func renameChecklistItem(_ item: ChecklistItem, to title: String, in task: TodoTask) async throws {
        try await write(taskURL(task, "/checklistItems/\(item.id)"), "PATCH", ["displayName": title])
    }

    func addChecklistItem(_ title: String, to task: TodoTask) async throws -> ChecklistItem {
        let data = try await write(taskURL(task, "/checklistItems"), "POST", ["displayName": title])
        return try JSONDecoder().decode(GraphChecklistItem.self, from: data).item
    }

    private static func dueBody(_ day: Date) -> [String: String] { timeBody(day) }

    /// `.../lists/{list}/tasks[/{task}][suffix]`; an empty task id addresses the list's task collection.
    private func taskURL(_ task: TodoTask, _ suffix: String = "") -> URL {
        var components = URLComponents(string: Self.base + "/me/todo/lists")!
        components.path += "/\(task.listID)/tasks" + (task.id.isEmpty ? "" : "/\(task.id)") + suffix
        return components.url!
    }

    @discardableResult
    private func write(_ url: URL, _ method: String, _ body: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(url, method: method, body: data)
    }

    /// Outlook master categories: name -> "#RRGGBB"
    func categoryColors() async throws -> [String: String] {
        do {
            return try Self.decodeCategoryColors(try await send(URL(string: Self.base + "/me/outlook/masterCategories")!))
        } catch let error as GraphError where error.status == 403 {
            return [:]  // MailboxSettings.Read may be blocked by tenant policy
        }
    }

    // MARK: - HTTP

    private func send(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        var token = try await auth.accessToken()
        var refreshed = false, waits = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let body {
                request.httpBody = body
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")  // only affects calendar endpoints
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            switch status {
            case 200..<300:
                return data
            case 401 where !refreshed:
                refreshed = true
                token = try await auth.refreshAccessToken()
            case 429 where waits < 3, 503 where waits < 3:
                waits += 1
                let seconds = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 5
                try await Task.sleep(for: .seconds(min(max(seconds, 1), 60)))
            default:
                struct Body: Decodable { struct E: Decodable { var code: String?; var message: String? }; var error: E? }
                let error = (try? JSONDecoder().decode(Body.self, from: data))?.error
                let detail = [error?.code, "HTTP \(status)"].compactMap(\.self).joined(separator: ", ")
                throw GraphError("\(error?.message ?? "Microsoft Graph request failed") (\(detail))", status: status)
            }
        }
    }

    private func paged<T>(_ url: URL, _ decode: @MainActor (Data) throws -> Page<T>) async throws -> [T] {
        var items: [T] = [], next: URL? = url
        while let url = next {
            let page = try decode(try await send(url))
            items += page.items
            next = page.next
        }
        return items
    }

    // MARK: - Decoding (pure, testable)

    struct Page<T> {
        var items: [T]
        var next: URL?
    }

    private struct OData<T: Decodable>: Decodable {
        var value: [T]
        var next: URL?
        enum CodingKeys: String, CodingKey { case value, next = "@odata.nextLink" }
    }

    private struct DateTimeTimeZone: Decodable { var dateTime: String }

    private struct GraphEvent: Decodable {
        struct Location: Decodable { var displayName: String? }
        struct Response: Decodable { var response: String? }
        struct Attendee: Decodable { struct Address: Decodable { var name: String?; var address: String? }; var emailAddress: Address? }
        struct Online: Decodable { var joinUrl: String? }
        var attendees: [Attendee]?
        var onlineMeeting: Online?
        var id: String
        var subject: String?
        var start: DateTimeTimeZone
        var end: DateTimeTimeZone
        var isAllDay: Bool?
        var location: Location?
        var categories: [String]?
        var showAs: String?
        var responseStatus: Response?
        var sensitivity: String?
        var type: String?
        var isOnlineMeeting: Bool?
        var isCancelled: Bool?
        var webLink: String?
    }

    static func decodeEvents(_ data: Data) throws -> Page<CalendarEvent> {
        let page = try JSONDecoder().decode(OData<GraphEvent>.self, from: data)
        var events: [CalendarEvent] = []
        for e in page.value {
            let allDay = e.isAllDay ?? false
            let parse = allDay ? localDay : utcDate
            guard let start = parse(e.start.dateTime), let end = parse(e.end.dateTime) else {
                throw GraphError("Unexpected date from Microsoft Graph: \(e.start.dateTime)")
            }
            let subject = e.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let location = e.location?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            events.append(CalendarEvent(
                id: e.id,
                title: subject.isEmpty ? "(No title)" : subject,
                start: start,
                end: end,
                isAllDay: allDay,
                location: location.isEmpty ? nil : location,
                categories: e.categories ?? [],
                showAs: e.showAs.flatMap(ShowAs.init) ?? .unknown,
                response: e.responseStatus?.response.flatMap(ResponseStatus.init) ?? .none,
                isPrivate: e.sensitivity == "private" || e.sensitivity == "confidential",
                isRecurring: (e.type ?? "singleInstance") != "singleInstance",
                isOnlineMeeting: e.isOnlineMeeting ?? false,
                isCancelled: e.isCancelled ?? false,
                webLink: e.webLink.flatMap(URL.init(string:)),
                attendees: (e.attendees ?? []).compactMap { $0.emailAddress?.name ?? $0.emailAddress?.address },
                joinURL: e.onlineMeeting?.joinUrl.flatMap(URL.init(string:))
            ))
        }
        return Page(items: events, next: page.next)
    }

    private struct GraphList: Decodable { var id: String; var displayName: String; var wellknownListName: String? }

    static func decodeLists(_ data: Data) throws -> Page<TaskList> {
        let page = try JSONDecoder().decode(OData<GraphList>.self, from: data)
        return Page(items: page.value.map { TaskList(id: $0.id, name: $0.displayName, isDefault: $0.wellknownListName == "defaultList", isFlagged: $0.wellknownListName == "flaggedEmails") }, next: page.next)
    }

    private struct GraphTask: Decodable {
        var id: String
        var title: String?
        var importance: String?
        var dueDateTime: DateTimeTimeZone?
        var body: Body?
        var recurrence: Recurrence?
        var isReminderOn: Bool?
        var reminderDateTime: DateTimeTimeZone?
        var completedDateTime: DateTimeTimeZone?

        struct Body: Decodable { var content: String?; var contentType: String? }
        struct Recurrence: Decodable {
            struct Pattern: Decodable { var type: String?; var interval: Int?; var daysOfWeek: [String]? }
            var pattern: Pattern?
        }

        func todo(in list: TaskList) -> TodoTask {
            var task = TodoTask(id: id, title: title ?? "", listName: list.name, listID: list.id,
                                due: dueDateTime.flatMap { GraphClient.dueDay($0.dateTime) },
                                isImportant: importance == "high")
            let content = body?.content ?? ""
            if body?.contentType == "html" {
                task.notes = GraphClient.plainText(fromHTML: content)
                task.notesReadOnly = !task.notes.isEmpty   // an empty HTML shell is safe to replace
            } else {
                task.notes = content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            task.repeats = recurrence?.pattern.flatMap { GraphClient.repeatRule(type: $0.type ?? "", interval: $0.interval ?? 1, days: $0.daysOfWeek ?? []) }
            if isReminderOn == true { task.reminder = reminderDateTime.flatMap { GraphClient.utcDate($0.dateTime) } }
            task.completed = completedDateTime.flatMap { GraphClient.utcDate($0.dateTime) }
            return task
        }
    }

    private struct GraphChecklistItem: Decodable {
        var id: String
        var displayName: String?
        var isChecked: Bool?
        var item: ChecklistItem { ChecklistItem(id: id, title: displayName ?? "", isChecked: isChecked ?? false) }
    }

    static func decodeChecklist(_ data: Data) throws -> Page<ChecklistItem> {
        let page = try JSONDecoder().decode(OData<GraphChecklistItem>.self, from: data)
        return Page(items: page.value.map(\.item), next: page.next)
    }

    /// Tags stripped by pattern, not rendered: rendering HTML would fetch any remote images in a note.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for (pattern, replacement) in [("(?is)<(style|script|head)[^>]*>.*?</\\1>", ""), ("(?i)<br\\s*/?>|</p>|</div>", "\n"), ("<[^>]+>", "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// shortcut: custom weekly days (say Mon and Wed) read as plain weekly; they are kept in To Do unless the repeat or due date is changed here.
    static func repeatRule(type: String, interval: Int, days: [String]) -> RepeatRule? {
        let unit: RepeatRule.Unit
        switch type {
        case "daily": unit = .daily
        case "weekly": unit = interval == 1 && Set(days.map { $0.lowercased() }) == Set(weekdayNames[1...5]) ? .weekdays : .weekly
        case "absoluteMonthly", "relativeMonthly": unit = .monthly
        case "absoluteYearly", "relativeYearly": unit = .yearly
        default: return nil
        }
        return RepeatRule(unit: unit, interval: unit == .weekdays ? 1 : max(interval, 1))
    }

    /// Graph's recurrence for a rule, falling on the due day's weekday, day of month or date.
    static func recurrenceBody(_ rule: RepeatRule, due: Date, calendar: Calendar = .laes) -> [String: Any] {
        let day = calendar.dateComponents([.year, .month, .day, .weekday], from: due)
        var pattern: [String: Any] = ["interval": rule.interval]
        switch rule.unit {
        case .daily: pattern["type"] = "daily"
        case .weekdays: pattern["type"] = "weekly"; pattern["interval"] = 1; pattern["daysOfWeek"] = Array(weekdayNames[1...5])
        case .weekly: pattern["type"] = "weekly"; pattern["daysOfWeek"] = [weekdayNames[day.weekday! - 1]]
        case .monthly: pattern["type"] = "absoluteMonthly"; pattern["dayOfMonth"] = day.day!
        case .yearly: pattern["type"] = "absoluteYearly"; pattern["dayOfMonth"] = day.day!; pattern["month"] = day.month!
        }
        return ["pattern": pattern, "range": ["type": "noEnd", "startDate": String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)]]
    }

    static func decodeTasks(_ data: Data, list: TaskList) throws -> Page<TodoTask> {
        let page = try JSONDecoder().decode(OData<GraphTask>.self, from: data)
        return Page(items: page.value.map { $0.todo(in: list) }, next: page.next)
    }

    static func decodeCategoryColors(_ data: Data) throws -> [String: String] {
        struct Category: Decodable { var displayName: String; var color: String }
        let page = try JSONDecoder().decode(OData<Category>.self, from: data)
        return Dictionary(page.value.compactMap { c in presetColors[c.color].map { (c.displayName, $0) } },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Graph dateTime ("2026-11-18T09:30:00.0000000", UTC, no zone suffix) -> Date.
    static func utcDate(_ s: String) -> Date? {
        try? Date(String(s.prefix(19)) + "Z", strategy: .iso8601)
    }

    /// A task's due day. To Do stores it as midnight in the zone the task was edited in (as UTC), and
    /// API-created tasks often use plain UTC midnight, so snap to the nearest local midnight.
    static func dueDay(_ s: String, calendar: Calendar = .laes) -> Date? {
        utcDate(s).map { calendar.startOfDay(for: $0.addingTimeInterval(12 * 3600)) }
    }

    /// Calendar day named by the date portion of a Graph dateTime, as local midnight in Calendar.laes.
    static func localDay(_ s: String) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.laes.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // shortcut: approximations of Outlook's category palette (Graph documents names only), adjust if they look off next to Outlook.
    static let presetColors: [String: String] = [
        "none": "#8A8886",
        "preset0": "#D13438", "preset1": "#F7630C", "preset2": "#8E562E", "preset3": "#FFB900",
        "preset4": "#13A10E", "preset5": "#00B7C3", "preset6": "#849B3B", "preset7": "#0078D4",
        "preset8": "#8764B8", "preset9": "#C50F1F", "preset10": "#69797E", "preset11": "#374649",
        "preset12": "#7A7574", "preset13": "#525252", "preset14": "#000000", "preset15": "#A4262C",
        "preset16": "#CA5010", "preset17": "#603D30", "preset18": "#986F0B", "preset19": "#0B6A0B",
        "preset20": "#038387", "preset21": "#5B5F23", "preset22": "#004E8C", "preset23": "#5C2E91",
        "preset24": "#750B1C",
    ]
}
