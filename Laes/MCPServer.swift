import Foundation
import Network
import UserNotifications

/// A parsed HTTP/1.1 request; nil while the bytes received so far are incomplete.
struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]   // names lowercased
    var body: Data

    init?(_ data: Data) {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return nil }
        method = String(start[0])
        path = String(start[1])
        headers = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let rest = data[split.upperBound...]
        guard rest.count >= length else { return nil }
        body = Data(rest.prefix(length))
    }
}

/// Model Context Protocol server for AI tools on this Mac: JSON-RPC over HTTP POST at /mcp, loopback only.
final class MCPServer {
    /// "lanes" on a phone keypad. The letters' places in the alphabet (12, 1, 14, 5, 19) don't fit below 65536.
    static let defaultPort = 52637
    /// Changeable in Settings, for when another program already uses it.
    static var port: UInt16 { UInt16(clamping: UserDefaults.standard.object(forKey: "mcpPort") as? Int ?? defaultPort) }
    static var url: String { "http://127.0.0.1:\(port)/mcp" }

    /// Callers must send this as a bearer token. Kept in the Keychain; one an earlier build kept in the preferences moves
    /// there unchanged, so connected tools keep working.
    static let token: String = {
        if let saved = Keychain.read("mcpToken") { return saved }
        let token = UserDefaults.standard.string(forKey: "mcpToken")
            ?? (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        if Keychain.write(token, account: "mcpToken") { UserDefaults.standard.removeObject(forKey: "mcpToken") }
        return token
    }()

    private unowned let store: AppStore
    private let listener: NWListener

    init(store: AppStore) throws {
        self.store = store
        _ = Self.token   // moves an older build's token out of the preferences now, not at the first request
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak store] state in
            guard case .failed(let error) = state else { return }
            Task { @MainActor in store?.mcpError = "The AI connection couldn't start: \(error.localizedDescription)" }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            Task { @MainActor in self?.receive(connection, Data()) }
        }
        listener.start(queue: .main)
    }

    func stop() { listener.cancel() }

    // MARK: HTTP

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                let buffer = buffer + (data ?? Data())
                if let request = HTTPRequest(buffer) {
                    let (status, body) = await self.respond(to: request)
                    let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                } else if isComplete || error != nil || buffer.count > 1_000_000 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer)
                }
            }
        }
    }

    func respond(to request: HTTPRequest) async -> (status: String, body: Data) {
        // Browsers send Origin on cross-site requests, and a rebound DNS name shows in Host: neither is a local tool.
        let hosts = ["127.0.0.1:\(Self.port)", "localhost:\(Self.port)"]
        guard request.headers["origin"] == nil, hosts.contains(request.headers["host"] ?? "") else { return ("403 Forbidden", Data()) }
        guard request.headers["authorization"] == "Bearer \(Self.token)" else { return ("401 Unauthorized", Data()) }
        guard request.path == "/mcp" else { return ("404 Not Found", Data()) }
        guard request.method == "POST" else { return ("405 Method Not Allowed", Data()) }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return ("400 Bad Request", Data())
        }
        guard let reply = await handle(message) else { return ("202 Accepted", Data()) }
        return ("200 OK", (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
    }

    // MARK: JSON-RPC

    /// The reply to one message; nil for notifications, which get none.
    func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            result = [
                "protocolVersion": ["2025-06-18", "2025-03-26", "2024-11-05"].contains(asked) ? asked : "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "laes", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
                "instructions": "The user's Microsoft 365 calendar, Microsoft To Do tasks and Markdown notes, through the lães app. Days are YYYY-MM-DD in the user's time zone. Find a meeting with list_events and a query (words from its title, place or attendees). Notes can be linked to one calendar event (event_id from list_events); the user is reminded of linked notes five minutes before that event. Use search_notes before answering from memory, and create a linked note to prepare the user for a meeting.",
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools]
        case "tools/call":
            do {
                guard store.isSignedIn else { throw GraphError("Nobody is signed in. Open lães and sign in with Microsoft first.") }
                let value = try await call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
                let text = String(data: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? ""
                result = ["content": [["type": "text", "text": text]], "isError": false]
            } catch {
                result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    // MARK: Tools

    private static func tool(_ name: String, _ description: String, _ properties: [String: String] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "required": required,
                         "properties": properties.mapValues { ["type": $0.hasPrefix("(boolean)") ? "boolean" : $0.hasPrefix("(integer)") ? "integer" : "string", "description": $0] }]]
    }

    static let tools: [[String: Any]] = [
        tool("sync", "Send any unsent changes to Microsoft and reload the calendar and tasks. Use before reading if freshness matters."),
        tool("list_events", "Calendar events between two days, or only those matching a search. Items the user has hidden as private are left out.",
             ["start": "First day, YYYY-MM-DD. Default: today.",
              "end": "Day after the last day, YYYY-MM-DD. Default: 14 days after start, or 8 weeks when searching.",
              "query": "Words to find in the title, place or attendees, like \"Peter 1:1\". Every word must match; case and accents don't matter."]),
        tool("get_event", "One calendar event with its description and organizer. Ids come from list_events.", ["id": "Event id"], required: ["id"]),
        tool("create_event", "Block time in the user's calendar: a private, busy meeting in the lães category.",
             ["title": "Title", "start": "Start, ISO 8601 with offset (2026-11-23T14:00:00+01:00) or local time (2026-11-23T14:00)", "minutes": "(integer) Length in minutes. Default 60."],
             required: ["title", "start"]),
        tool("list_task_lists", "The user's Microsoft To Do lists."),
        tool("list_tasks", "Open (not completed) tasks, as of the last sync. Tasks the user has hidden as private are left out.",
             ["list": "Only this list: its id or name."]),
        tool("get_task", "One open task with its notes and steps (subtasks).", ["id": "Task id"], required: ["id"]),
        tool("create_task", "Add a task to Microsoft To Do.",
             ["title": "Title", "due": "Due day, YYYY-MM-DD", "list": "List id or name. Default: the user's default list.", "notes": "Notes; Markdown is shown formatted."],
             required: ["title"]),
        tool("update_task", "Change an open task. Only the given fields change.",
             ["id": "Task id", "title": "New title", "due": "New due day, YYYY-MM-DD; an empty string removes it", "notes": "New notes, replacing the old ones",
              "important": "(boolean) Mark or unmark as important", "reminder": "Reminder time like 2026-11-23T09:00; an empty string turns it off",
              "repeat": "One of never, daily, weekdays, weekly, monthly, yearly. Falls on the due day's weekday or date; sets the due date to today if there is none.",
              "interval": "(integer) With repeat: every how many days, weeks, months or years. Default 1.",
              "completed": "(boolean) true marks the task as completed"],
             required: ["id"]),
        tool("search_notes", "Full-text search over the user's notes, best matches first, each with the matching line. Use get_note for the whole text.",
             ["query": "Words to look for", "limit": "(integer) Most results to return. Default 10."], required: ["query"]),
        tool("list_notes", "All notes, newest first, without their text. Notes of meetings the user has hidden as private are left out.", ["event_id": "Only notes linked to this calendar event."]),
        tool("get_note", "One note with its Markdown text and the event it is linked to.", ["name": "The note's file name, from search_notes or list_notes"], required: ["name"]),
        tool("create_note", "Write a new Markdown note into the user's OneDrive notes folder. Link it to a calendar event to have the user reminded of it five minutes before.",
             ["title": "Title", "body": "The note in Markdown, without the title or a front matter header", "event_id": "Calendar event to link it to, from list_events"],
             required: ["title", "body"]),
        tool("update_note", "Change a note. Only the given fields change.",
             ["name": "The note's file name", "title": "New title", "body": "New Markdown text, replacing the old", "append": "Markdown to add at the end instead of replacing",
              "event_id": "Calendar event to link it to; an empty string removes the link"],
             required: ["name"]),
    ]

    private func call(_ name: String, _ args: [String: Any]) async throws -> Any {
        func day(_ key: String) throws -> Date? {
            guard let text = args[key] as? String else { return nil }
            guard let date = GraphClient.localDay(text) else { throw GraphError("\(key) must be a day like 2026-11-23.") }
            return date
        }
        func list() throws -> TaskList? {
            guard let wanted = args["list"] as? String else { return nil }
            let lists = store.visibleLists   // not the private ones while they are hidden, by name or in the error
            guard let list = lists.first(where: { $0.id == wanted || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw GraphError("No list called \(wanted). Lists: \(lists.map(\.name).joined(separator: ", "))")
            }
            return list
        }
        func task() throws -> TodoTask {
            let id = args["id"] as? String ?? ""
            guard let task = store.visibleTasks.first(where: { $0.id == id || $0.id == store.adopted[id] }) else {   // a hidden one stays hidden to a tool that kept its id
                throw GraphError("No open task with that id. It may be completed or deleted; list_tasks shows the current ones.")
            }
            return task
        }

        func note() throws -> Note {
            guard store.notesEnabled else { throw GraphError("Notes are off. The user can turn them on in lães under Notes.") }
            guard let note = store.visibleNotes.first(where: { $0.name == args["name"] as? String }) else {
                throw GraphError("No note with that name. list_notes shows the current ones.")
            }
            return note
        }
        /// nil if no event_id was given; .some(nil) for an empty one (unlink).
        func linkedEvent() async throws -> CalendarEvent?? {
            guard let id = args["event_id"] as? String else { return nil }
            if id.isEmpty { return .some(nil) }
            let event: CalendarEvent
            if let loaded = store.events.first(where: { $0.id == id }) { event = loaded } else { event = try await GraphClient(auth: store.auth).eventDetails(id: id).event }
            guard store.showPrivate || !hasCategory(event.categories, in: store.privateCategories) else { throw GraphError("No event with that id.") }
            return event
        }

        switch name {
        case "search_notes":
            guard store.notesEnabled else { throw GraphError("Notes are off. The user can turn them on in lães under Notes.") }
            return searchNotes(store.visibleNotes, args["query"] as? String ?? "", limit: args["limit"] as? Int ?? 10).map { hit in
                var json = Self.json(hit.note, withBody: false)
                json["score"] = (hit.score * 100).rounded() / 100
                json["snippet"] = hit.snippet
                return json
            }

        case "list_notes":
            guard store.notesEnabled else { throw GraphError("Notes are off. The user can turn them on in lães under Notes.") }
            let eventID = args["event_id"] as? String
            return store.visibleNotes.filter { eventID == nil || $0.eventID == eventID }.sorted { $0.modified > $1.modified }.map { Self.json($0, withBody: false) }

        case "get_note":
            return Self.json(try note(), withBody: true)

        case "create_note":
            guard store.notesEnabled else { throw GraphError("Notes are off. The user can turn them on in lães under Notes.") }
            guard let title = args["title"] as? String, let body = args["body"] as? String else { throw GraphError("title and body are required.") }
            let created = store.addNote(title: title, body: body, event: try await linkedEvent() ?? nil)
            await store.sendNotes()
            return Self.json(store.notes.first { $0.name == created.name } ?? created, withBody: false)

        case "update_note":
            var note = try note()
            var body = args["body"] as? String
            if let more = args["append"] as? String { body = (body ?? note.body) + "\n\n" + more }
            note.update(title: args["title"] as? String, body: body)
            if let event = try await linkedEvent() { note.link(to: event) }
            store.saveNote(note)
            await store.sendNotes()
            return Self.json(store.notes.first { $0.name == note.name } ?? note, withBody: false)

        case "sync":
            await store.refresh()
            return ["offline": store.isOffline, "unsentChanges": store.pending.count,
                    "lastSync": store.lastSync.map(Self.time) ?? NSNull(), "error": store.errorMessage ?? NSNull()]

        case "list_events":
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let start = try day("start") ?? Calendar.laes.startOfDay(for: .now)
            let end = try day("end") ?? Calendar.laes.date(byAdding: .day, value: query.isEmpty ? 14 : 56, to: start)!
            let events = try await GraphClient(auth: store.auth).events(from: start, to: end)
            return events
                .filter { store.showPrivate || !hasCategory($0.categories, in: store.privateCategories) }
                .filter { $0.matches(query) }
                .sorted { $0.start < $1.start }
                .map { event in
                    var json = Self.json(event)
                    json["notes"] = store.notes(for: event).map(\.name)
                    return json
                }

        case "get_event":
            let details = try await GraphClient(auth: store.auth).eventDetails(id: args["id"] as? String ?? "")
            guard store.showPrivate || !hasCategory(details.event.categories, in: store.privateCategories) else {
                throw GraphError("No event with that id.")
            }
            var json = Self.json(details.event)
            json["description"] = details.description
            json["organizer"] = details.organizer
            json["notes"] = store.notes(for: details.event).map(\.name)
            return json

        case "create_event":
            guard let title = args["title"] as? String, let start = (args["start"] as? String).flatMap(Self.parseTime) else {
                throw GraphError("title and a start time like 2026-11-23T14:00 are required.")
            }
            let before = store.errorMessage
            guard let event = await store.addEvent(title: title, start: start, minutes: args["minutes"] as? Int ?? 60) else {
                defer { store.errorMessage = before }   // reported to the caller instead of the window
                throw GraphError(store.errorMessage ?? "The meeting couldn't be created.")
            }
            return Self.json(event)

        case "list_task_lists":
            return store.taskLists
                .filter { store.showPrivate || !store.privateListIDs.contains($0.id) }
                .map { ["id": $0.id, "name": $0.name, "isDefault": $0.isDefault] }

        case "list_tasks":
            let only = try list()
            return store.visibleTasks.filter { only == nil || $0.listID == only!.id }.map { Self.json($0) }

        case "get_task":
            let task = try task()
            await store.loadChecklist(for: task)
            return Self.json(task, steps: store.checklists[task.id] ?? [])

        case "create_task":
            guard let title = args["title"] as? String, let created = store.addTask(title: title, due: try day("due"), listID: try list()?.id) else {
                throw GraphError("A title is required.")
            }
            await store.sendPending()   // so the caller gets the id Microsoft assigned
            guard var task = store.tasks.first(where: { $0.id == store.adopted[created.id] ?? created.id }) else { return Self.json(created) }
            if let notes = args["notes"] as? String {
                store.setNotes(task, notes)
                task.notes = notes
            }
            return Self.json(task)

        case "update_task":
            var task = try task()
            if let title = args["title"] as? String { store.rename(task, to: title) }
            if args["due"] as? String == "" { store.setDue(task, nil) } else if let due = try day("due") { store.setDue(task, due) }
            if let important = args["important"] as? Bool { store.setImportant(task, important) }
            if let text = args["reminder"] as? String {
                guard text.isEmpty || Self.parseTime(text) != nil else { throw GraphError("reminder must be a time like 2026-11-23T09:00.") }
                store.setReminder(task, Self.parseTime(text))
            }
            if let text = args["repeat"] as? String {
                let unit = RepeatRule.Unit(rawValue: text.lowercased())
                guard unit != nil || text.lowercased() == "never" else { throw GraphError("repeat must be never, daily, weekdays, weekly, monthly or yearly.") }
                store.setRepeat(task, unit.map { RepeatRule(unit: $0, interval: $0 == .weekdays ? 1 : max(args["interval"] as? Int ?? 1, 1)) })
            }
            task = store.tasks.first { $0.id == task.id } ?? task
            if let notes = args["notes"] as? String {
                guard !task.notesReadOnly else { throw GraphError("This task's note has Outlook formatting and can only be edited in Outlook.") }
                store.setNotes(task, notes)
                task.notes = notes
            }
            let completed = args["completed"] as? Bool ?? false
            if completed { store.complete(task) }
            await store.sendPending()
            var json = Self.json(task)
            json["completed"] = completed
            return json

        default:
            throw GraphError("Unknown tool \(name).")
        }
    }

    // MARK: JSON shapes

    private static func time(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle(timeZone: .current)) }
    private static func dayText(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()) }

    static func parseTime(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = text.count > 16 ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd'T'HH:mm"
        return local.date(from: text)
    }

    #if DEBUG
    /// `-mcpCheck`: plays an AI tool through the server's own HTTP door, with its token: finds the next meeting, writes
    /// a note for it, reads it back, checks its reminder is scheduled, then deletes the note. The outcome (no meeting
    /// titles or note text) goes to ~/Library/Logs/laes-mcp-check.txt.
    static func check(_ store: AppStore) async {
        var log: [String] = []
        func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let (data, response) = try await URLSession.shared.data(for: request)
            log.append("\(method)\(params["name"].map { " \($0)" } ?? ""): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any] ?? [:]
        }
        func tool(_ name: String, _ arguments: [String: Any]) async throws -> Any {
            let result = try await call("tools/call", ["name": name, "arguments": arguments])
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            if result["isError"] as? Bool == true { log.append("  error: \(text)"); throw GraphError(text) }
            return try JSONSerialization.jsonObject(with: Data(text.utf8))
        }
        do {
            let server = try await call("initialize", ["protocolVersion": "2025-06-18"])
            log.append("  server: \((server["serverInfo"] as? [String: Any])?["name"] ?? "?")")
            log.append("  tools: \(((try await call("tools/list"))["tools"] as? [Any])?.count ?? 0)")
            let events = try await tool("list_events", [:]) as? [[String: Any]] ?? []
            log.append("  meetings in the next two weeks: \(events.count)")
            guard let meeting = events.first(where: {
                ($0["allDay"] as? Bool) == false && ($0["cancelled"] as? Bool) == false
                    && (($0["start"] as? String).flatMap(parseTime) ?? .distantPast) > .now.addingTimeInterval(15 * 60)
            }), let id = meeting["id"] as? String else { throw GraphError("No upcoming meeting to try it on.") }
            log.append("  picked the meeting starting \(meeting["start"] ?? "?")")
            let words: [Substring] = (meeting["title"] as? String ?? "").split(whereSeparator: \.isWhitespace)
            let word = words.max { $0.count < $1.count }.map(String.init) ?? ""
            let found = try await tool("list_events", ["query": word]) as? [[String: Any]] ?? []
            log.append("  searching a word of its title finds it: \(found.contains { $0["id"] as? String == id }) (\(found.count) of the next 8 weeks' meetings match)")
            let note = try await tool("create_note", ["title": "lães check", "body": "Written through the AI connection to test reminders. Safe to delete.", "event_id": id]) as? [String: Any] ?? [:]
            let name = note["name"] as? String ?? ""
            log.append("  note created, saved to OneDrive: \(note["savedToOneDrive"] ?? "?"), linked: \((note["event_id"] as? String) == id)")
            let linked = try await tool("list_notes", ["event_id": id]) as? [[String: Any]] ?? []
            log.append("  list_notes for the meeting finds it: \(linked.contains { $0["name"] as? String == name })")
            try await Task.sleep(for: .seconds(3))   // reminders are scheduled on their own task
            let center = UNUserNotificationCenter.current()
            let permission = await center.notificationSettings().authorizationStatus
            let pending = await center.pendingNotificationRequests()
            log.append("  notifications allowed: \(permission == .authorized) (status \(permission.rawValue)), reminder scheduled: \(pending.contains { $0.identifier == id })")
            if let reminder = pending.first(where: { $0.identifier == id }),
               let date = (reminder.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() {
                log.append("  reminder at \(date.formatted(.iso8601)), \(Int(((meeting["start"] as? String).flatMap(parseTime) ?? date).timeIntervalSince(date) / 60)) min before the start")
            }
            if let made = store.notes.first(where: { $0.name == name }) { await store.deleteNote(made) }
            log.append("  test note deleted: \(!store.notes.contains { $0.name == name })")
        } catch {
            log.append("FAILED: \(error.localizedDescription)")
        }
        let file = URL.libraryDirectory.appending(path: "Logs/laes-mcp-check.txt")
        try? log.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    #endif

    private static func json(_ event: CalendarEvent) -> [String: Any] {
        var json: [String: Any] = [
            "id": event.id, "title": event.title, "allDay": event.isAllDay,
            "start": event.isAllDay ? dayText(event.start) : time(event.start),
            "end": event.isAllDay ? dayText(event.end) : time(event.end),
            "showAs": event.showAs.rawValue, "response": event.response.rawValue,
            "categories": event.categories, "attendees": event.attendees,
            "cancelled": event.isCancelled, "createdInLaes": event.isOwn,
        ]
        json["location"] = event.location
        json["joinURL"] = event.joinURL?.absoluteString
        return json
    }

    private static func json(_ note: Note, withBody: Bool) -> [String: Any] {
        var json: [String: Any] = ["name": note.name, "title": note.title, "modified": time(note.modified), "savedToOneDrive": !note.isDirty]
        json["event_id"] = note.eventID
        json["event_title"] = note.meta("event_title")
        json["event_start"] = note.eventStart.map(time)
        if withBody { json["body"] = note.body }
        return json
    }

    private static func json(_ task: TodoTask, steps: [ChecklistItem]? = nil) -> [String: Any] {
        var json: [String: Any] = ["id": task.id, "title": task.title, "list": task.listName, "important": task.isImportant, "notes": task.notes]
        json["due"] = task.due.map(dayText)
        json["repeats"] = task.recurrence
        json["reminder"] = task.reminder.map(time)
        json["steps"] = steps?.map { ["title": $0.title, "done": $0.isChecked] }
        return json
    }
}
