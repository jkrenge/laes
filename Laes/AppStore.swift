import Foundation
import Network
import Observation

@Observable
final class AppStore {
    var events: [CalendarEvent] = []
    var tasks: [TodoTask] = []
    var taskLists: [TaskList] = []
    /// Outlook category name -> "#RRGGBB"
    var categoryColors: [String: String] = [:]
    /// Saturday that starts the first of the two visible weeks.
    var weekStart = Calendar.laes.weekStart(for: .now)
    var isSignedIn = false
    var isSyncing = false
    var errorMessage: String?
    var lastSync: Date?
    /// Subtasks by task id, filled in as tasks are opened.
    var checklists: [String: [ChecklistItem]] = [:]
    var isOffline = false
    /// Task edits not yet sent to Microsoft, oldest first.
    private(set) var pending: [PendingEdit] = []

    // The private group: hidden everywhere while `showPrivate` is off.
    var showPrivate = UserDefaults.standard.object(forKey: "showPrivate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPrivate, forKey: "showPrivate") }
    }
    var privateCategories = Set(UserDefaults.standard.stringArray(forKey: "privateCategories") ?? ["Private", "Privat"]) {
        didSet { UserDefaults.standard.set(privateCategories.sorted(), forKey: "privateCategories") }
    }
    var privateListIDs = Set(UserDefaults.standard.stringArray(forKey: "privateListIDs") ?? []) {
        didSet { UserDefaults.standard.set(privateListIDs.sorted(), forKey: "privateListIDs") }
    }

    // Layout preferences; `Calendar.laes` and `WeekRow` read the same defaults keys.
    var firstWeekday = UserDefaults.standard.object(forKey: "firstWeekday") as? Int ?? 7 {
        didSet {
            UserDefaults.standard.set(firstWeekday, forKey: "firstWeekday")
            goToToday()
        }
    }
    var firstHour = UserDefaults.standard.object(forKey: "firstHour") as? Int ?? 7 {
        didSet { UserDefaults.standard.set(firstHour, forKey: "firstHour") }
    }
    var lastHour = UserDefaults.standard.object(forKey: "lastHour") as? Int ?? 20 {
        didSet { UserDefaults.standard.set(lastHour, forKey: "lastHour") }
    }

    #if os(macOS)
    /// The local MCP server for AI tools (off unless the user turns it on).
    var mcpEnabled = UserDefaults.standard.bool(forKey: "mcpEnabled") {
        didSet {
            UserDefaults.standard.set(mcpEnabled, forKey: "mcpEnabled")
            applyMCP()
        }
    }
    var mcpPort = Int(MCPServer.port) {
        didSet {
            UserDefaults.standard.set(mcpPort, forKey: "mcpPort")
            applyMCP()
        }
    }
    var mcpError: String?
    @ObservationIgnored private var mcp: MCPServer?
    private func applyMCP() {
        mcp?.stop()
        mcp = nil
        mcpError = nil
        guard mcpEnabled else { return }
        do {
            mcp = try MCPServer(store: self)
        } catch {
            mcpError = error.localizedDescription
        }
    }
    #endif

    // Notes: Markdown files in OneDrive. On by default; Settings can switch them off.
    var notes: [Note] = []
    var notesEnabled = UserDefaults.standard.object(forKey: "notesEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notesEnabled, forKey: "notesEnabled") }
    }
    var notesError: String?
    /// File name of a note some view asked to show (a reminder, an event); the Notes view takes it.
    var openNote: String?
    @ObservationIgnored private var notesUpload: Task<Void, Never>?

    /// Task id -> the list it is being moved to, while the move is under way.
    private(set) var moving: [String: String] = [:]

    /// Temporary task id -> the id Microsoft assigned, for callers that created a task and want its real id.
    @ObservationIgnored private(set) var adopted: [String: String] = [:]

    /// What the calendar draws: with the private group hidden, its meetings stay as anonymous blocks of time.
    var calendarEvents: [CalendarEvent] {
        showPrivate ? events : events.map { hasCategory($0.categories, in: privateCategories) ? $0.redacted : $0 }
    }
    /// Without the private group while it is hidden: for reminders, and wherever a meeting's details would show.
    var visibleEvents: [CalendarEvent] {
        showPrivate ? events : events.filter { !hasCategory($0.categories, in: privateCategories) }
    }
    var visibleTasks: [TodoTask] {
        showPrivate ? tasks : tasks.filter { !privateListIDs.contains($0.listID) }
    }

    let auth = AuthService()
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var wantsFlush = false
    @ObservationIgnored private var wantsFetch = false
    @ObservationIgnored private var lastFetchFailed = false
    @ObservationIgnored private var refetchAfterCompleting: Set<String> = []
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        // `-demo` shows the sample data without touching the account, for screenshots.
        isSignedIn = !ProcessInfo.processInfo.arguments.contains("-demo") && auth.hasSession   // demo first: no Keychain prompt
        if isSignedIn { loadCache() } else { loadSample() }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.connectivityChanged(online: online) }
        }
        monitor.start(queue: .global(qos: .utility))
        NoteReminders.shared.start { [weak self] in self?.openNote = $0 }
        #if os(macOS)
        applyMCP()
        #endif
    }

    /// Days of events loaded from `weekStart`. iOS scrolls day by day, so it keeps two more weeks at hand.
    #if os(macOS)
    static let rangeDays = 14
    #else
    static let rangeDays = 28
    #endif

    /// Makes sure `day` and the week after it are loaded (iOS, where the calendar scrolls freely).
    func show(day: Date) {
        let loadedEnd = Calendar.laes.date(byAdding: .day, value: 14, to: weekStart)!
        guard day < weekStart || day >= loadedEnd else { return }
        weekStart = Calendar.laes.weekStart(for: day)
        Task { await refresh() }
    }

    var visibleRange: DateInterval {
        DateInterval(start: weekStart, end: Calendar.laes.date(byAdding: .day, value: Self.rangeDays, to: weekStart)!)
    }

    func shiftWeeks(_ n: Int) {
        weekStart = Calendar.laes.date(byAdding: .day, value: 7 * n, to: weekStart)!
        Task { await refresh() }
    }

    func goToToday() {
        weekStart = Calendar.laes.weekStart(for: .now)
        Task { await refresh() }
    }

    func signIn() async {
        do {
            try await auth.signIn()
            isSignedIn = true
            (events, tasks, taskLists, checklists, categoryColors, notes) = ([], [], [], [:], [:], [])   // drop the sample data
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        auth.signOut()
        isSignedIn = false
        pending = []
        checklists = [:]
        notes = []
        Disk.removeAll()
        loadSample()
    }

    // MARK: Sync

    /// Sends queued edits, then reloads from Microsoft. Returns when both are done (or it turned out to be offline).
    func refresh() async {
        guard isSignedIn else { return loadSample() }
        await kick(fetch: true).value
    }

    /// Sends queued edits without reloading. Returns when the queue is empty or sending had to stop.
    func sendPending() async {
        guard isSignedIn else { return }
        await kick(fetch: false).value
    }

    /// For coming back to the app: reloads unless it just did.
    func refreshIfStale() async {
        if lastSync.map({ $0.timeIntervalSinceNow < -60 }) ?? true { await refresh() }
    }

    /// One runner at a time, so a reload never overlaps sending: an edit made during a reload stays
    /// queued, is re-applied on top of the reloaded data, and goes out on the next pass.
    @discardableResult
    private func kick(fetch: Bool) -> Task<Void, Never> {
        wantsFlush = true
        wantsFetch = wantsFetch || fetch
        if let runner { return runner }
        let task = Task {
            while wantsFlush || wantsFetch {
                wantsFlush = false
                let sent = await flush()
                if wantsFetch {
                    wantsFetch = false
                    if sent { await reload() }
                }
            }
            runner = nil
        }
        runner = task
        return task
    }

    /// Sends queued edits in order. False if it had to stop: offline, throttled, or signed out.
    private func flush() async -> Bool {
        let graph = GraphClient(auth: auth)
        while let edit = pending.first {
            let task = TodoTask(id: edit.taskID, title: "", listName: "", listID: edit.listID)
            do {
                switch edit.kind {
                case .create(let title, let due):
                    if let list = taskLists.first(where: { $0.id == edit.listID }) {
                        adopt(try await graph.createTask(title: title, due: due, in: list).id, for: edit.taskID)
                    }
                case .complete:
                    try await graph.completeTask(task)
                    if refetchAfterCompleting.remove(edit.taskID) != nil {
                        // Microsoft creates a repeating task's next occurrence a moment after the completion lands.
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            await refresh()
                        }
                    }
                case .setDue(let day):
                    try await graph.setDue(task, day: day)
                case .setTitle(let title):
                    try await graph.setTitle(task, title)
                case .setImportant(let important):
                    try await graph.setImportant(task, important)
                case .setReminder(let date):
                    try await graph.setReminder(task, date)
                case .setRepeat(let rule, let due):
                    try await graph.setRepeat(task, rule, due: due)
                case .setNotes(let text):
                    try await graph.setNotes(task, text)
                case .checkStep(let id, let checked):
                    try await graph.setChecked(ChecklistItem(id: id, title: ""), checked, in: task)
                case .renameStep(let id, let title):
                    try await graph.renameChecklistItem(ChecklistItem(id: id, title: ""), to: title, in: task)
                case .addStep(let id, let title):
                    adopt(try await graph.addChecklistItem(title, to: task).id, for: id)
                }
                isOffline = false
            } catch let error as GraphError where (400..<500).contains(error.status) && error.status != 401 && error.status != 429 {
                // Microsoft refused it (for example the task was deleted elsewhere). Retrying can't help:
                // drop the edit, say so, and reload what is really there.
                errorMessage = "A change couldn't be saved: \(error.localizedDescription)"
                wantsFetch = true
            } catch {
                if error is URLError {
                    isOffline = true
                } else {
                    errorMessage = error.localizedDescription
                    isSignedIn = auth.hasSession   // an expired session clears the Keychain
                }
                return false
            }
            pending.removeFirst()   // still this edit: the queue only grows at the end while we wait
            persist()
        }
        return true
    }

    private func reload() async {
        isSyncing = true
        defer { isSyncing = false }
        let range = visibleRange
        let graph = GraphClient(auth: auth)
        do {
            async let e = graph.events(from: range.start, to: range.end)
            async let t = graph.tasks()
            async let c = graph.categoryColors()
            let (events, (lists, tasks), colors) = try await (e, t, c)
            // Navigated away meanwhile: that navigation already asked for another reload.
            guard range == visibleRange else { return }
            self.events = events
            self.taskLists = ordered(lists, by: listOrder)
            self.tasks = applying(pending, to: tasks, lists: lists)
            self.categoryColors = colors
            checklists = checklists.filter { id, _ in self.tasks.contains { $0.id == id } }
            if lastFetchFailed { errorMessage = nil }
            lastFetchFailed = false
            isOffline = false
            lastSync = .now
            persist()
            // Offline launches open on the current weeks, so only those are worth keeping.
            if weekStart == Calendar.laes.weekStart(for: .now) {
                try? Disk.save(EventSnapshot(weekStart: weekStart, events: events), to: "events.json")
            }
            await syncNotes()
        } catch is URLError {
            isOffline = true
        } catch {
            errorMessage = error.localizedDescription
            lastFetchFailed = true
            isSignedIn = auth.hasSession
        }
    }

    private func connectivityChanged(online: Bool) {
        guard online else { return isOffline = true }
        // Back online: catch up. (Also called once at launch, when there is nothing to catch up on.)
        guard isSignedIn, isOffline || !pending.isEmpty else { return }
        Task { await refresh() }
    }

    /// A create has been sent: swap the temporary id for Microsoft's everywhere it is used.
    private func adopt(_ new: String, for old: String) {
        adopted[old] = new
        pending = replacingID(old, with: new, in: pending)
        if let index = tasks.firstIndex(where: { $0.id == old }) { tasks[index].id = new }
        if let steps = checklists.removeValue(forKey: old) { checklists[new] = steps }
        for (taskID, steps) in checklists {
            if let index = steps.firstIndex(where: { $0.id == old }) { checklists[taskID]![index].id = new }
        }
    }

    // MARK: Own meetings
    // shortcut: sent straight to Microsoft, not through the offline queue, so they need a connection; queue them if offline use matters.

    /// A one-hour private meeting in the lães category.
    @discardableResult
    func addEvent(title: String, start: Date, minutes: Int = 60) async -> CalendarEvent? {
        let end = start.addingTimeInterval(Double(minutes) * 60)
        var event = CalendarEvent(id: UUID().uuidString, title: title, start: start, end: end, categories: [ownCategory], isPrivate: true)
        do {
            if isSignedIn { event = try await GraphClient(auth: auth).createEvent(title: title, start: start, end: end) }
            events.append(event)
            return event
        } catch {
            errorMessage = "The meeting couldn't be created: \(error.localizedDescription)"
            return nil
        }
    }

    func setEnd(of event: CalendarEvent, to end: Date) async {
        guard event.isOwn, end != event.end, let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index].end = end
        guard isSignedIn else { return }
        do {
            try await GraphClient(auth: auth).setEnd(event, to: end)
        } catch {
            errorMessage = "The meeting couldn't be changed: \(error.localizedDescription)"
            if let index = events.firstIndex(where: { $0.id == event.id }) { events[index].end = event.end }
        }
    }

    func deleteEvent(_ event: CalendarEvent) async {
        guard event.isOwn else { return }
        do {
            if isSignedIn { try await GraphClient(auth: auth).deleteEvent(event) }
            events.removeAll { $0.id == event.id }
        } catch {
            errorMessage = "The meeting couldn't be deleted: \(error.localizedDescription)"
        }
    }

    // MARK: Notes

    /// Asks Microsoft for the OneDrive folder (a sign-in with one more permission), then loads the notes.
    func enableNotes() async {
        notesEnabled = true
        do {
            try await auth.signIn()
            await refresh()
        } catch {
            notesEnabled = false
            errorMessage = "Notes couldn't be turned on: \(error.localizedDescription)"
        }
    }

    /// Without the notes of private meetings while the private group is hidden. A note knows its meeting's
    /// categories from its header; one linked before that was recorded is matched to the loaded meeting instead.
    var visibleNotes: [Note] {
        if showPrivate { return notes }
        return notes.filter { note in
            let categories = note.meta("event_categories") != nil ? note.eventCategories
                : events.first { $0.id == note.eventID }?.categories ?? []
            return !hasCategory(categories, in: privateCategories)
        }
    }

    func notes(for event: CalendarEvent) -> [Note] { visibleNotes.filter { $0.eventID == event.id } }

    /// A new note, its title as the first heading; one for a meeting is linked to it and named after its day.
    /// Without a title it starts as "# ", ready to be typed, and gets its file name on the first save.
    @discardableResult
    func addNote(title: String = "", body: String = "", event: CalendarEvent? = nil) -> Note {
        notes.removeAll { $0.isBlank && $0.tag.isEmpty }   // notes started earlier and left empty; the list hides them
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = event.map { $0.start.formatted(.iso8601.year().month().day()) + " " } ?? ""
        let name = noteFileName(for: title.isEmpty ? untitledNote : day + title, taken: notes.map(\.name))
        var note = Note(name: name, text: body.hasPrefix("# ") ? body : title.isEmpty ? "# " + body : "# \(title)\n\n\(body)")
        note.link(to: event)
        keep(note)
        return note
    }

    /// Returns the note's file name, which changes when an untitled note gets its title.
    @discardableResult
    func saveNote(_ note: Note) -> String {
        guard let old = notes.first(where: { $0.name == note.name }), old.text != note.text else { return note.name }
        var note = note
        // shortcut: only before the first upload, since OneDrive would need a rename after it; a second save racing that upload can leave an "Untitled" copy behind.
        if note.tag.isEmpty, note.name.hasPrefix(untitledNote), let heading = note.heading {
            notes.removeAll { $0.name == old.name }
            note.name = noteFileName(for: heading, taken: notes.map(\.name))
        }
        keep(note)
        return note.name
    }

    /// Kept here at once and marked unsent; uploading follows, now or when back online. The last writer wins.
    private func keep(_ note: Note) {
        var note = note
        note.modified = .now
        note.isDirty = isSignedIn
        notes.removeAll { $0.name == note.name }
        notes.insert(note, at: 0)
        persistNotes()
        uploadNotes()
        scheduleReminders()
    }

    func deleteNote(_ note: Note) async {
        do {
            if isSignedIn, !note.tag.isEmpty { try await GraphClient(auth: auth).deleteNote(name: note.name) }
            notes.removeAll { $0.name == note.name }
            persistNotes()
            scheduleReminders()
        } catch {
            errorMessage = "The note couldn't be deleted: \(error.localizedDescription)"
        }
    }

    /// Returns when every changed note is in OneDrive, or uploading had to stop.
    func sendNotes() async { await uploadNotes().value }

    /// One upload pass after the other, so two saves of a note can't overtake each other.
    @discardableResult
    private func uploadNotes() -> Task<Void, Never> {
        let previous = notesUpload
        let task = Task {
            await previous?.value
            guard isSignedIn, notesEnabled else { return }
            let graph = GraphClient(auth: auth)
            for note in notes where note.isDirty && !note.isBlank {
                do {
                    let file = try await graph.saveNote(name: note.name, text: note.text)
                    guard let index = notes.firstIndex(where: { $0.name == note.name }) else { continue }
                    notes[index].tag = file.tag
                    if notes[index].text == note.text { notes[index].isDirty = false }
                    notesError = nil
                } catch let error as GraphError {
                    notesError = "Notes couldn't be saved to OneDrive: \(error.localizedDescription)"
                    break
                } catch {
                    break   // offline: they stay marked and go out with the next sync
                }
            }
            persistNotes()
        }
        notesUpload = task
        return task
    }

    /// Uploads what changed here, then takes over what changed in OneDrive (for example notes an AI tool or another device wrote).
    private func syncNotes() async {
        guard notesEnabled else { return }
        await sendNotes()
        do {
            let graph = GraphClient(auth: auth)
            var fresh: [Note] = []
            for file in try await graph.noteFiles() {
                if let have = notes.first(where: { $0.name == file.name && $0.tag == file.tag }) {
                    fresh.append(have)
                } else {
                    fresh.append(Note(name: file.name, text: try await graph.noteText(file), modified: file.modified, tag: file.tag))
                }
            }
            let unsent = notes.filter(\.isDirty)
            notes = unsent + fresh.filter { file in !unsent.contains { $0.name == file.name } }
            notesError = nil
            persistNotes()
        } catch let error as GraphError {
            notesError = "Notes couldn't be loaded from OneDrive: \(error.localizedDescription)"
        } catch {}
        scheduleReminders()
    }

    private func scheduleReminders() {
        guard isSignedIn else { return }   // no reminders for sample data
        let meetings = NoteReminders.meetings(for: visibleNotes, loaded: events)
        Task { await NoteReminders.shared.schedule(meetings) }
    }

    private func persistNotes() {
        if isSignedIn { try? Disk.save(notes, to: "notes.json") }
    }

    // MARK: Lists
    // shortcut: sent straight to Microsoft like own meetings, so they need a connection; queue them if offline use matters.

    private var listOrder: [String] { UserDefaults.standard.stringArray(forKey: "listOrder") ?? [] }

    func addList(_ name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            taskLists.append(isSignedIn ? try await GraphClient(auth: auth).createList(name: name) : TaskList(id: UUID().uuidString, name: name))
            persist()
        } catch {
            errorMessage = "The list couldn't be created: \(error.localizedDescription)"
        }
    }

    func renameList(_ list: TaskList, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != list.name else { return }
        do {
            if isSignedIn { try await GraphClient(auth: auth).renameList(list, to: name) }
            if let index = taskLists.firstIndex(where: { $0.id == list.id }) { taskLists[index].name = name }
            for index in tasks.indices where tasks[index].listID == list.id { tasks[index].listName = name }
            persist()
        } catch {
            errorMessage = "The list couldn't be renamed: \(error.localizedDescription)"
        }
    }

    /// Deletes the list and all its tasks, here and at Microsoft.
    func deleteList(_ list: TaskList) async {
        await sendPending()   // so no queued edit is left pointing at a list that is gone
        do {
            if isSignedIn { try await GraphClient(auth: auth).deleteList(list) }
            taskLists.removeAll { $0.id == list.id }
            tasks.removeAll { $0.listID == list.id }
            privateListIDs.remove(list.id)
            persist()
        } catch {
            errorMessage = "The list couldn't be deleted: \(error.localizedDescription)"
        }
    }

    /// Reorders the lists as shown (hidden private lists keep to the end). Kept on this device only.
    func setListOrder(_ shown: [TaskList]) {
        taskLists = shown + taskLists.filter { !shown.contains($0) }
        UserDefaults.standard.set(taskLists.map(\.id), forKey: "listOrder")
        persist()
    }

    // MARK: Task edits (applied here at once, then queued for Microsoft)

    /// Adds a task, due on `day` if given, to the named list or else To Do's default list.
    @discardableResult
    func addTask(title: String, due day: Date?, listID: String? = nil) -> TodoTask? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let list = taskLists.first(where: { $0.id == listID })
                ?? taskLists.first(where: \.isDefault) ?? taskLists.first else { return nil }
        let task = TodoTask(id: temporaryIDPrefix + UUID().uuidString, title: title, listName: list.name, listID: list.id, due: day)
        tasks.append(task)
        enqueue(.create(title: title, due: day), for: task)
        return task
    }

    func complete(_ task: TodoTask) {
        tasks.removeAll { $0.id == task.id }
        checklists[task.id] = nil
        if task.recurrence != nil { refetchAfterCompleting.insert(task.id) }
        enqueue(.complete, for: task)
    }

    /// Moves a task to another list. Sent at once, not queued: Microsoft gives the moved task a new id.
    /// Queued edits go out first, so they land on the old task and are copied along.
    func moveTask(_ task: TodoTask, to list: TaskList) async {
        guard isSignedIn else {   // sample data
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { (tasks[index].listID, tasks[index].listName) = (list.id, list.name) }
            return
        }
        moving[task.id] = list.id
        await sendPending()
        let id = adopted[task.id] ?? task.id
        moving[id] = list.id   // a task created moments ago has Microsoft's id by now
        defer { moving[task.id] = nil; moving[id] = nil }
        guard let current = tasks.first(where: { $0.id == id }), current.listID != list.id else { return }
        do {
            guard !pending.contains(where: { $0.taskID == id }) else { throw GraphError("You're offline.") }
            let moved = try await GraphClient(auth: auth).moveTask(current, to: list)
            adopted[id] = moved.id
            tasks.removeAll { $0.id == id }
            tasks.append(moved)
            checklists[id] = nil
            persist()
            await loadChecklist(for: moved)
        } catch {
            errorMessage = "“\(current.title)” couldn't be moved to \(list.name): \(error.localizedDescription)"
        }
    }

    /// Changes the due date to `day` (a local midnight).
    func move(taskID: String, to day: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].due != day else { return }
        tasks[index].due = day
        enqueue(.setDue(day), for: tasks[index])
    }

    func rename(_ task: TodoTask, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        edit(task, .setTitle(title)) { $0.title = title }
    }

    func setImportant(_ task: TodoTask, _ important: Bool) {
        edit(task, .setImportant(important)) { $0.isImportant = important }
    }

    /// `day` is a local midnight; nil removes the due date (and the repeat, which needs one).
    /// A repeating task is re-sent with its rule, so the repeat falls on the new day's weekday or date.
    func setDue(_ task: TodoTask, _ day: Date?) {
        if let rule = tasks.first(where: { $0.id == task.id })?.repeats {
            if let day { return edit(task, .setRepeat(rule, due: day)) { $0.due = day } }
            setRepeat(task, nil)   // a repeat needs a due date, so it goes first
        }
        edit(task, .setDue(day)) { $0.due = day }
    }

    func setReminder(_ task: TodoTask, _ date: Date?) {
        edit(task, .setReminder(date)) { $0.reminder = date }
    }

    /// A repeating task needs a due date: one without gets today.
    func setRepeat(_ task: TodoTask, _ rule: RepeatRule?) {
        guard let current = tasks.first(where: { $0.id == task.id }), current.repeats != rule else { return }
        let due = current.due ?? Calendar.laes.startOfDay(for: .now)
        edit(task, .setRepeat(rule, due: due)) { ($0.repeats, $0.due) = (rule, due) }
    }

    /// Applies a change here and queues it for Microsoft, unless it changes nothing.
    private func edit(_ task: TodoTask, _ kind: PendingEdit.Kind, _ change: (inout TodoTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let before = tasks[index]
        change(&tasks[index])
        if tasks[index] != before { enqueue(kind, for: tasks[index]) }
    }

    func setNotes(_ task: TodoTask, _ text: String) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }), tasks[index].notes != text else { return }
        tasks[index].notes = text
        enqueue(.setNotes(text), for: task)
    }

    /// Fetches a task's subtasks when it is opened. Offline, the saved copy (if any) stays.
    func loadChecklist(for task: TodoTask) async {
        guard isSignedIn, !task.id.hasPrefix(temporaryIDPrefix),
              let steps = try? await GraphClient(auth: auth).checklist(of: task) else { return }
        checklists[task.id] = applying(pending, toSteps: steps, of: task.id)
        persist()
    }

    func toggleStep(_ step: ChecklistItem, in task: TodoTask) {
        guard let index = checklists[task.id]?.firstIndex(where: { $0.id == step.id }) else { return }
        checklists[task.id]![index].isChecked.toggle()
        enqueue(.checkStep(stepID: step.id, checked: !step.isChecked), for: task)
    }

    func renameStep(_ step: ChecklistItem, to title: String, in task: TodoTask) {
        guard let index = checklists[task.id]?.firstIndex(where: { $0.id == step.id }),
              checklists[task.id]![index].title != title else { return }
        checklists[task.id]![index].title = title
        enqueue(.renameStep(stepID: step.id, title: title), for: task)
    }

    func addStep(_ title: String, to task: TodoTask) {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let step = ChecklistItem(id: temporaryIDPrefix + UUID().uuidString, title: title)
        checklists[task.id, default: []].append(step)
        enqueue(.addStep(stepID: step.id, title: title), for: task)
    }

    private func enqueue(_ kind: PendingEdit.Kind, for task: TodoTask) {
        guard isSignedIn else { return }   // sample data is local only
        pending.append(PendingEdit(taskID: task.id, listID: task.listID, kind: kind))
        persist()
        kick(fetch: false)
    }

    // MARK: Local copy

    private func persist() {
        guard isSignedIn else { return }
        do {
            try Disk.save(pending, to: "outbox.json")
            try Disk.save(TaskSnapshot(tasks: tasks, taskLists: taskLists, categoryColors: categoryColors,
                                       checklists: checklists, lastSync: lastSync), to: "tasks.json")
        } catch {
            errorMessage = "Couldn't save your data for offline use: \(error.localizedDescription)"
        }
    }

    private func loadCache() {
        pending = Disk.loadList(PendingEdit.self, from: "outbox.json") ?? []
        notes = Disk.loadList(Note.self, from: "notes.json") ?? []
        if let saved = Disk.load(TaskSnapshot.self, from: "tasks.json") {
            (tasks, taskLists, categoryColors, checklists, lastSync) =
                (saved.tasks, ordered(saved.taskLists, by: listOrder), saved.categoryColors, saved.checklists, saved.lastSync)
        }
        if let saved = Disk.load(EventSnapshot.self, from: "events.json"), saved.weekStart == weekStart {
            events = saved.events
        }
    }

    private func loadSample() {
        events = SampleData.events(weekStart: weekStart)
        tasks = SampleData.tasks(weekStart: weekStart).map { var t = $0; t.listID = t.listName; return t }
        taskLists = Set(tasks.map(\.listName)).sorted().map { TaskList(id: $0, name: $0) }
        categoryColors = SampleData.categoryColors
        if notes.isEmpty, let meeting = events.first(where: { !$0.isAllDay }) {
            var note = Note(name: "Sample.md", text: "# \(meeting.title)\n\n## Agenda\n- [x] Review last week\n- [ ] **Decide** the next steps\n\nNotes are plain Markdown files.")
            note.link(to: meeting)
            notes = [note]
        }
    }
}
