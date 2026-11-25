import SwiftUI

/// Which part of a planned (dated) task list to show.
enum PlannedFilter: String, CaseIterable {
    case all = "All Planned", overdue = "Overdue", dueNow = "Overdue & Today", today = "Today", tomorrow = "Tomorrow", week = "This Week", later = "Later"

    /// `due` is a local midnight. "This Week" runs from today to the end of the current week; "Later" is after that.
    func contains(_ due: Date, today: Date, calendar: Calendar = .laes) -> Bool {
        let start = calendar.startOfDay(for: today)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: calendar.weekStart(for: today))!
        switch self {
        case .all: return true
        case .dueNow: return due <= start
        case .overdue: return due < start
        case .today: return due == start
        case .tomorrow: return due == tomorrow
        case .week: return due >= start && due < weekEnd
        case .later: return due >= weekEnd
        }
    }

    /// The due day of a task added under this filter, so it lands where it was added.
    func newTaskDay(today: Date, calendar: Calendar = .laes) -> Date {
        let start = calendar.startOfDay(for: today)
        switch self {
        case .tomorrow: return calendar.date(byAdding: .day, value: 1, to: start)!
        case .later: return calendar.date(byAdding: .day, value: 7, to: calendar.weekStart(for: today))!
        default: return start
        }
    }

    var addPrompt: String {
        switch self {
        case .tomorrow: "Add a task due tomorrow"
        case .later: "Add a task due next week"
        default: "Add a task due today"
        }
    }
}

/// How a flat task list is ordered. Ties fall back to due day, then title.
enum TaskSort: String, CaseIterable {
    case due = "Due Date", list = "List", title = "Title", important = "Importance"
}

/// What a task list shows: one of the built-in views, or one To Do list.
enum TaskSource: Hashable {
    case planned, important, all, list(String)
}

extension AppStore {
    /// To Do lists, without the private group while it is hidden.
    var visibleLists: [TaskList] {
        taskLists.filter { showPrivate || !privateListIDs.contains($0.id) }
    }

    func tasks(in source: TaskSource) -> [TodoTask] {
        visibleTasks.filter { task in
            switch source {
            case .planned: task.due != nil
            case .important: task.isImportant
            case .all: true
            case .list(let id): task.listID == id
            }
        }
    }

    func title(of source: TaskSource) -> String {
        switch source {
        case .planned: "Planned"
        case .important: "Important"
        case .all: "All"
        case .list(let id): taskLists.first { $0.id == id }?.name ?? "Tasks"
        }
    }

    /// The tasks of `source` as one flat list in the chosen order.
    /// `addedLast`: tasks just added here, kept at the end in the order added, so a new one never lands mid-list.
    func sortedTasks(in source: TaskSource, planned: PlannedFilter, now: Date, by sort: TaskSort, addedLast: [String] = []) -> [TodoTask] {
        // Lists in the order the overview shows them: Microsoft's built-in ones, then the user's own in their order.
        let shown = visibleLists.filter(\.isBuiltIn) + visibleLists.filter { !$0.isBuiltIn }
        let position = Dictionary(shown.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = addedLast.map { adopted[$0] ?? $0 }   // sent tasks have Microsoft's id by now
        func key(_ task: TodoTask) -> (Int, Int, String, Date, String) {
            let first = switch sort {
            case .due, .title: 0
            case .list: position[task.listID] ?? .max
            case .important: task.isImportant ? 0 : 1
            }
            return ((added.firstIndex(of: task.id) ?? -1) + 1, first, sort == .title ? task.title.lowercased() : "", task.due ?? .distantFuture, task.title)
        }
        return tasks(in: source)
            .filter { source != .planned || planned.contains($0.due!, today: now) }
            .sorted { key($0) < key($1) }
    }

}

/// Due-date shortcuts offered for a task.
enum QuickDue: CaseIterable {
    case today, tomorrow, nextWeek, nextWeekend

    var title: String {
        switch self {
        case .today: "Due Today"
        case .tomorrow: "Due Tomorrow"
        case .nextWeek: "Due Next Week"
        case .nextWeekend: "Due Next Weekend"
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .today: "1"
        case .tomorrow: "2"
        case .nextWeek: "3"
        case .nextWeekend: "4"
        }
    }

    /// Next week starts on the coming Monday, the next weekend on the coming Saturday (both after today).
    func day(from now: Date, calendar: Calendar = .laes) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .tomorrow: return calendar.date(byAdding: .day, value: 1, to: today)!
        case .nextWeek: return calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
        case .nextWeekend: return calendar.nextDate(after: today, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime)!
        }
    }
}

/// Words in a new task's title that set its due day or star it, as in "Call mom tomorrow".
/// The add bar underlines them, and they are left out of the title.
struct QuickAdd {
    var title: String
    var due: Date?
    var dueWords: Range<String.Index>?   // "on Friday", in the typed text
    var starWord: Range<String.Index>?
    var isImportant: Bool { starWord != nil }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]   // Calendar's order
    // Whole words only: "today's" and "Mondays" are just words.
    private static let dueRegex = try! NSRegularExpression(
        pattern: #"(?<!\S)(?:(?:on|by|due)\s+)?(today|tomorrow|next week|next month|\#(weekdays.joined(separator: "|")))(?=$|\s|[.,;:!?])"#,
        options: .caseInsensitive)
    private static let starRegex = try! NSRegularExpression(
        pattern: #"(?<!\S)(star|priority)(?=$|\s|[.,;:!?])"#, options: .caseInsensitive)

    /// `ignoring`: matched words (lowercased) the user dismissed, so they stay part of the title.
    init(_ text: String, now: Date, ignoring: Set<String> = [], calendar: Calendar = .laes) {
        func first(_ regex: NSRegularExpression) -> (all: Range<String.Index>, word: String)? {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).lazy
                .compactMap { match in Range(match.range, in: text).flatMap { all in Range(match.range(at: 1), in: text).map { (all, text[$0].lowercased()) } } }
                .first { !ignoring.contains(text[$0.all].lowercased()) }
        }
        let today = calendar.startOfDay(for: now)
        if let (range, word) = first(Self.dueRegex) {
            dueWords = range
            due = switch word {
            case "today": today
            case "tomorrow": QuickDue.tomorrow.day(from: now, calendar: calendar)
            case "next week": QuickDue.nextWeek.day(from: now, calendar: calendar)   // the coming Monday
            case "next month": calendar.date(byAdding: .month, value: 1, to: calendar.dateInterval(of: .month, for: today)!.start)
            default: calendar.nextDate(after: today, matching: DateComponents(weekday: Self.weekdays.firstIndex(of: word)! + 1), matchingPolicy: .nextTime)
            }
        }
        starWord = first(Self.starRegex)?.all
        var rest = text
        for range in [dueWords, starWord].compactMap({ $0 }).sorted(by: { $0.lowerBound > $1.lowerBound }) { rest.removeSubrange(range) }
        title = dueWords == nil && starWord == nil ? text : rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension AppStore {
    /// Adds a task typed into an add bar: a day or star in its words wins over the bar's own day.
    func addTask(_ quick: QuickAdd, otherwise day: Date?, listID: String?) -> TodoTask? {
        guard let task = addTask(title: quick.title, due: quick.due ?? day, listID: listID) else { return nil }
        if quick.isImportant { setImportant(task, true) }
        return task
    }
}

/// The day and star an add bar's draft names, as badges to float above the bar. Removing one keeps its word in the title.
struct QuickAddBadges: View {
    let quick: QuickAdd
    let draft: String
    @Binding var ignored: Set<String>

    var body: some View {
        HStack(spacing: 8) {
            if let due = quick.due, let words = quick.dueWords {
                badge(title(of: due), "calendar", Color.brandText) { ignored.insert(draft[words].lowercased()) }
            }
            if let word = quick.starWord {
                badge("Important", "star.fill", Color.important) { ignored.insert(draft[word].lowercased()) }
            }
        }
        .animation(.snappy, value: quick.due)
    }

    private func badge(_ title: String, _ icon: String, _ tint: Color, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title)
                Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(Color.subtle)
            }
            #if os(iOS)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .glassCapsule()
            #else
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.separator))
            #endif
        }
        .buttonStyle(.plain)
        .help("Remove; the word stays in the title")
        .accessibilityLabel(title)
        .accessibilityHint("Removes it; the word stays in the title")
    }

    private func title(of due: Date) -> String {
        switch Calendar.laes.dateComponents([.day], from: Calendar.laes.startOfDay(for: .now), to: due).day {
        case 0: "Today"
        case 1: "Tomorrow"
        default: due.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }
}

/// The words QuickAdd found, underlined, to lay over a one-line field's own text. Hidden once the text no longer fits.
struct QuickAddUnderline: View {
    let quick: QuickAdd
    let text: String

    var body: some View {
        var shown = AttributedString(text)
        for range in [quick.dueWords, quick.starWord].compactMap({ $0 }) {
            if let range = Range(range, in: shown) { shown[range].underlineStyle = Text.LineStyle(pattern: .solid, color: Color.brandText) }
        }
        return ViewThatFits(in: .horizontal) {
            Text(shown).foregroundStyle(.clear).lineLimit(1)
            Color.clear
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Completing and quick due dates for one task: its context menu, and the Task menu for the selected task.
struct TaskActions: View {
    @Environment(AppStore.self) private var store
    let task: TodoTask?

    var body: some View {
        Button("Mark as Completed", systemImage: "checkmark.circle") { if let task { store.complete(task) } }
            .keyboardShortcut(.return)
            .disabled(task == nil)
        Divider()
        ForEach(QuickDue.allCases, id: \.self) { when in
            Button(when.title) { if let task { store.setDue(task, when.day(from: .now)) } }
                .keyboardShortcut(when.key)
                .disabled(task == nil)
        }
        Button("Remove Due Date") { if let task { store.setDue(task, nil) } }
            .keyboardShortcut("0")
            .disabled(task?.due == nil)
    }
}

extension FocusedValues {
    @Entry var selectedTask: TodoTask?
}

/// A list change waiting for the user's input.
enum ListEdit: Equatable {
    case new, rename(TaskList), delete(TaskList)
}

/// The prompts for naming a new list, renaming one and confirming a delete, shared by both apps.
struct ListEditor: ViewModifier {
    @Environment(AppStore.self) private var store
    @Binding var edit: ListEdit?
    @State private var name = ""

    private var deleted: TaskList? {
        if case .delete(let list) = edit { list } else { nil }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: edit) {
                if case .rename(let list) = edit { name = list.name } else { name = "" }
            }
            .alert(edit == .new ? "New List" : "Rename List",
                   isPresented: Binding(get: { edit != nil && deleted == nil }, set: { if !$0 { edit = nil } }), presenting: edit) { edit in
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button(edit == .new ? "Create" : "Rename") {
                    let name = name   // read now: closing the alert clears the field before the task runs
                    Task {
                        if case .rename(let list) = edit { await store.renameList(list, to: name) } else { await store.addList(name) }
                    }
                }
            }
            .alert("Delete “\(deleted?.name ?? "")”?",
                   isPresented: Binding(get: { deleted != nil }, set: { if !$0 { edit = nil } }), presenting: deleted) { list in
                Button("Delete", role: .destructive) { Task { await store.deleteList(list) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The list and all its tasks are deleted from Microsoft To Do. This can't be undone.")
            }
    }
}

/// Rename and Delete for one list. To Do's built-in list can be neither.
struct ListActions: View {
    let list: TaskList
    @Binding var edit: ListEdit?

    var body: some View {
        if !list.isBuiltIn {
            Button("Rename", systemImage: "pencil") { edit = .rename(list) }
            Button("Delete", systemImage: "trash", role: Self.deleteRole) { edit = .delete(list) }
                .tint(Color.overdue)   // red without the role on iPhone; the app tint would make it purple
        }
    }

    #if os(iOS)
    // A destructive swipe action removes its row at once, before the alert confirms; the list then crashed.
    private static let deleteRole: ButtonRole? = nil
    #else
    private static let deleteRole: ButtonRole? = .destructive
    #endif
}

/// Shown for a few seconds after reordering lists, where the eye already is.
struct OrderNote: View {
    @Binding var isShown: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("Microsoft To Do can't sync the order of lists, so this order is only stored on this device.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark") { isShown = false }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(Color.subtle)
        .task {
            try? await Task.sleep(for: .seconds(6))
            isShown = false
        }
    }
}

#if os(macOS)
/// All open tasks: views and lists on the left, the chosen tasks in the middle, one task's details on the right.
struct TaskListView: View {
    @Environment(AppStore.self) private var store
    let now: Date
    var isShown = true   // hidden behind another view: its fields take no focus, and the Task menu doesn't see its selection

    @State private var source: TaskSource? = .planned
    @AppStorage("plannedFilter") private var planned = PlannedFilter.dueNow   // the last one used
    @State private var showOrderNote = false
    @State private var draft = ""
    @State private var ignored: Set<String> = []   // words in the draft the user said aren't a date or a star
    @State private var selectedID: String?   // task shown in the details panel
    @State private var listEdit: ListEdit?
    @State private var added: [String] = []   // tasks added to the open list, shown last
    @AppStorage("taskSort") private var sort = TaskSort.list

    private var current: TaskSource { source ?? .planned }
    private var today: Date { Calendar.laes.startOfDay(for: now) }
    private var lists: [TaskList] { store.visibleLists.filter { !$0.isBuiltIn } }   // the user's own, reorderable
    private var shown: [TodoTask] { store.sortedTasks(in: current, planned: planned, now: now, by: sort, addedLast: added) }
    private var title: String { store.title(of: current) }
    private func tasks(in source: TaskSource) -> [TodoTask] { store.tasks(in: source) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                taskList
                if current != .important { addBar.disabled(!isShown) }
            }
            if let task = selected {
                Divider()
                ScrollView {
                    TaskDetails(task: task, close: { selectedID = nil })
                        .id(selectedID)   // fresh state per task; the old one saves its note as it goes
                }
                .frame(width: 352)
                .background(Color.primary.opacity(0.035))
                .disabled(!isShown)
            }
        }
        .focusedSceneValue(\.selectedTask, isShown ? selected : nil)
        .onChange(of: source) { added = [] }
    }

    private var selected: TodoTask? {
        let id = selectedID.map { store.adopted[$0] ?? $0 }   // a task moved to another list has a new id
        return store.visibleTasks.first { $0.id == id }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $source) {
            Section {
                sidebarRow("Planned", "calendar", .planned)
                sidebarRow("Important", "star", .important)
                sidebarRow("All", "tray.full", .all)
                ForEach(store.visibleLists.filter(\.isBuiltIn)) { sidebarRow($0.name, $0.icon, .list($0.id)) }
            }
            Section("Lists") {
                ForEach(lists) { list in
                    Text(list.name).badge(tasks(in: .list(list.id)).count).tag(TaskSource.list(list.id))
                        .contextMenu { ListActions(list: list, edit: $listEdit) }
                }
                .onMove { from, to in
                    var shown = lists
                    shown.move(fromOffsets: from, toOffset: to)
                    store.setListOrder(shown)
                    showOrderNote = true
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                if showOrderNote {
                    OrderNote(isShown: $showOrderNote)
                        .padding(8)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.horizontal, 10)
                }
                Button("New List", systemImage: "plus") { listEdit = .new }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.subtle)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .modifier(ListEditor(edit: $listEdit))
        .onChange(of: store.visibleLists.map(\.id)) { _, ids in
            if case .list(let id) = current, !ids.contains(id) { source = .planned }   // the open list was deleted
        }
    }

    private func sidebarRow(_ name: String, _ icon: String, _ source: TaskSource) -> some View {
        Label(name, systemImage: icon).badge(tasks(in: source).count).tag(source)
    }

    // MARK: Content

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Sort by", systemImage: "arrow.up.arrow.down", selection: $sort) {
                    ForEach(TaskSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Sort tasks")
            }
            if current == .planned {
                HStack(spacing: 6) {
                    ForEach(PlannedFilter.allCases, id: \.self) { filter in
                        Button(filter.rawValue) { planned = filter }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(planned == filter ? Color.white : Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(planned == filter ? Color.brand : Color.primary.opacity(0.07), in: Capsule())
                            .accessibilityAddTraits(planned == filter ? .isSelected : [])
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var taskList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { task in
                        TaskListRow(task: task, today: today, showsList: !isSingleList, isSelected: task.id == selected?.id) {
                            selectedID = selected?.id == task.id ? nil : task.id
                        }
                    }
                    if shown.isEmpty {
                        Text("Nothing here").foregroundStyle(Color.subtle).padding(40).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .onChange(of: added) { _, ids in if let id = ids.last { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
        }
    }

    private var isSingleList: Bool {
        if case .list = current { true } else { false }
    }

    /// New tasks go to the open list (else To Do's default list); in Planned they are due on the filter's day.
    /// A day or "star" typed into the title is underlined, shown as a badge above, and applied instead.
    private var addBar: some View {
        let quick = QuickAdd(draft, now: now, ignoring: ignored)
        return HStack(spacing: 10) {
            Image(systemName: "plus").foregroundStyle(Color.subtle)
            TextField(current == .planned ? planned.addPrompt : "Add a task", text: $draft)
                .textFieldStyle(.plain)
                .overlay(alignment: .leading) { QuickAddUnderline(quick: quick, text: draft) }
                .onSubmit {
                    var listID: String?
                    if case .list(let id) = current { listID = id }
                    guard let task = store.addTask(quick, otherwise: current == .planned ? planned.newTaskDay(today: now) : nil, listID: listID) else { return }
                    added.append(task.id)
                    (draft, ignored) = ("", [])
                }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topLeading) {
            QuickAddBadges(quick: quick, draft: draft, ignored: $ignored)
                .alignmentGuide(.top) { $0[.bottom] + 8 }   // above the bar without moving the list
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

#endif

/// Title over a line of details (list, due day, repeat, note). Tapping shows the task's details.
struct TaskListRow: View {
    @Environment(AppStore.self) private var store
    let task: TodoTask
    let today: Date
    let showsList: Bool
    let isSelected: Bool
    let select: () -> Void

    private var isOverdue: Bool { task.due.map { $0 < today } ?? false }
    private var target: String? { store.moving[task.id] }   // list it is being moved to

    private var dueText: String? {
        guard let due = task.due else { return nil }
        switch Calendar.laes.dateComponents([.day], from: today, to: due).day {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            #if os(macOS)
            CompleteButton(title: task.title) { store.complete(task) }
            #else
            Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(Color.subtle)
            #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).lineLimit(1).foregroundStyle(target == nil ? Color.primary : Color.subtle)
                HStack(spacing: 8) {
                    if let target {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Moving to \(store.taskLists.first { $0.id == target }?.name ?? "list")")
                        }
                    } else if showsList {
                        Text(task.listName)
                    }
                    if let dueText {
                        // Not a Label: in a list those reserve a wide icon column.
                        HStack(spacing: 3) { Image(systemName: "calendar"); Text(dueText) }
                            .foregroundStyle(isOverdue ? Color.overdue : Color.brandText)
                    }
                    if task.recurrence != nil { Image(systemName: "arrow.triangle.2.circlepath").accessibilityLabel("Repeats") }
                    if !task.notes.isEmpty { HStack(spacing: 3) { Image(systemName: "note.text"); Text("Note") } }
                }
                .font(.caption)
                .foregroundStyle(Color.subtle)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            if task.isImportant {
                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color.important).accessibilityLabel("Important")
            }
        }
        #if os(macOS)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.brand.opacity(0.22) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        #else
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.brand.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, -8)
        #endif
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu { TaskActions(task: task) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: "Mark as Completed") { store.complete(task) }
    }
}
