import Foundation

// Offline support: a saved copy of the last sync, and a saved queue of task edits not yet sent.

/// A task edit waiting to be sent to Microsoft. Saved to disk so it survives quitting while offline.
struct PendingEdit: Codable, Hashable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case create(title: String, due: Date?)
        case complete
        case setDue(Date?)
        case setNotes(String)
        case setTitle(String)
        case setImportant(Bool)
        case setReminder(Date?)
        case setRepeat(RepeatRule?, due: Date)
        case checkStep(stepID: String, checked: Bool)
        case renameStep(stepID: String, title: String)
        case addStep(stepID: String, title: String)
    }
    var taskID: String   // temporary (see `temporaryIDPrefix`) until the task's create has been sent
    var listID: String
    var kind: Kind
}

/// Ids of tasks and subtasks created here and not yet known to Microsoft.
let temporaryIDPrefix = "new-"

/// Re-applies unsent edits on top of freshly fetched tasks, so they don't flicker away after a sync.
func applying(_ edits: [PendingEdit], to tasks: [TodoTask], lists: [TaskList]) -> [TodoTask] {
    var tasks = tasks
    for edit in edits {
        let index = tasks.firstIndex { $0.id == edit.taskID }
        switch edit.kind {
        case .create(let title, let due):
            if index == nil, let list = lists.first(where: { $0.id == edit.listID }) {
                tasks.append(TodoTask(id: edit.taskID, title: title, listName: list.name, listID: list.id, due: due))
            }
        case .complete:
            if let index { tasks.remove(at: index) }
        case .setDue(let day):
            if let index { tasks[index].due = day }
        case .setNotes(let text):
            if let index { tasks[index].notes = text }
        case .setTitle(let title):
            if let index { tasks[index].title = title }
        case .setImportant(let important):
            if let index { tasks[index].isImportant = important }
        case .setReminder(let date):
            if let index { tasks[index].reminder = date }
        case .setRepeat(let rule, let due):
            if let index { (tasks[index].repeats, tasks[index].due) = (rule, due) }
        case .checkStep, .renameStep, .addStep:
            break
        }
    }
    return tasks
}

/// The same for one task's subtasks.
func applying(_ edits: [PendingEdit], toSteps steps: [ChecklistItem], of taskID: String) -> [ChecklistItem] {
    var steps = steps
    for edit in edits where edit.taskID == taskID {
        switch edit.kind {
        case .checkStep(let id, let checked):
            if let index = steps.firstIndex(where: { $0.id == id }) { steps[index].isChecked = checked }
        case .renameStep(let id, let title):
            if let index = steps.firstIndex(where: { $0.id == id }) { steps[index].title = title }
        case .addStep(let id, let title):
            if !steps.contains(where: { $0.id == id }) { steps.append(ChecklistItem(id: id, title: title)) }
        case .create, .complete, .setDue, .setNotes, .setTitle, .setImportant, .setReminder, .setRepeat:
            break
        }
    }
    return steps
}

/// Once a create has been sent, later edits must address the id Microsoft assigned (task or subtask).
func replacingID(_ old: String, with new: String, in edits: [PendingEdit]) -> [PendingEdit] {
    edits.map { edit in
        var edit = edit
        if edit.taskID == old { edit.taskID = new }
        switch edit.kind {
        case .checkStep(old, let checked): edit.kind = .checkStep(stepID: new, checked: checked)
        case .renameStep(old, let title): edit.kind = .renameStep(stepID: new, title: title)
        case .addStep(old, let title): edit.kind = .addStep(stepID: new, title: title)
        default: break
        }
        return edit
    }
}

/// Microsoft keeps no list order to sync, so the user's order (list ids) lives on this device; unknown lists go last.
func ordered(_ lists: [TaskList], by order: [String]) -> [TaskList] {
    lists.enumerated().sorted { a, b in
        (order.firstIndex(of: a.element.id) ?? order.count + a.offset) < (order.firstIndex(of: b.element.id) ?? order.count + b.offset)
    }.map(\.element)
}

struct TaskSnapshot: Codable {
    var tasks: [TodoTask]
    var taskLists: [TaskList]
    var categoryColors: [String: String]
    var checklists: [String: [ChecklistItem]]
    var lastSync: Date?
}

struct EventSnapshot: Codable {
    var weekStart: Date
    var events: [CalendarEvent]
}

/// Plain JSON files in Application Support on this device, unencrypted like Outlook's own local cache.
/// Each file records the format version it was written in. A file that doesn't read is moved aside, never overwritten,
/// and lists (the unsent edits, notes with unsent changes) are read item by item, so one unreadable item costs only itself.
enum Disk {
    static var folder = URL.applicationSupportDirectory.appending(path: "app.laes.Laes", directoryHint: .isDirectory)   // tests point it elsewhere

    /// Raise this when a saved type changes so that older files no longer decode, and read the older version in `load`.
    static let version = 1

    fileprivate struct File<Value> { var version: Int; var value: Value }

    /// An item that reads as nil instead of failing the whole list.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        if let value = (try? JSONDecoder().decode(File<T>.self, from: data))?.value ?? (try? JSONDecoder().decode(T.self, from: data)) {
            return value   // the second: saved before files had versions
        }
        setAside(name)
        return nil
    }

    /// A saved list, keeping every item that still reads; if any doesn't, the file is also copied aside as it was.
    static func loadList<T: Decodable>(_ type: T.Type, from name: String) -> [T]? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        guard let items = (try? JSONDecoder().decode(File<[Lossy<T>]>.self, from: data))?.value
                ?? (try? JSONDecoder().decode([Lossy<T>].self, from: data)) else {
            setAside(name)
            return nil
        }
        if items.contains(where: { $0.value == nil }) { setAside(name, keepingOriginal: true) }
        return items.compactMap(\.value)
    }

    static func save(_ value: some Encodable, to name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(File(version: version, value: value)).write(to: url(name), options: .atomic)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func url(_ name: String) -> URL { folder.appending(path: name) }

    /// Kept next to it as "<name>.unread-<time>" for a later build (or support) to recover.
    private static func setAside(_ name: String, keepingOriginal: Bool = false) {
        let target = url("\(name).unread-\(Int(Date.now.timeIntervalSince1970))")
        if keepingOriginal { try? FileManager.default.copyItem(at: url(name), to: target) } else { try? FileManager.default.moveItem(at: url(name), to: target) }
    }
}

extension Disk.File: Decodable where Value: Decodable {}
extension Disk.File: Encodable where Value: Encodable {}
