import SwiftUI

/// Where the Tasks tab opens, set in Settings › Behavior.
enum TasksStart: String { case lists, dueNow }

/// Views and lists. On iPhone tapping one pushes its tasks, and a task opens as a drawer. On iPad the lists,
/// the chosen list's tasks and the chosen task's details sit side by side, a third of the width each.
struct TasksScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var listEdit: ListEdit?
    @State private var showOrderNote = false
    @State private var path: [TaskSource] = []
    @State private var source: TaskSource?   // iPad: the open list
    @State private var task: TodoTask?   // iPad: the open task
    @State private var visibility = NavigationSplitViewVisibility.all
    @AppStorage("tasksStart") private var start = TasksStart.lists
    @AppStorage("plannedFilter") private var planned = PlannedFilter.dueNow

    var body: some View {
        if sizeClass == .regular { columns } else { stack }
    }

    private var stack: some View {
        NavigationStack(path: $path) {
            lists(List { rows })
                .navigationDestination(for: TaskSource.self) { TaskListScreen(source: $0) }
                .appToolbar()
        }
        .onChange(of: start, initial: true) {
            if start == .dueNow { (planned, path) = (.dueNow, [.planned]) } else { path = [] }
        }
    }

    private var columns: some View {
        GeometryReader { geo in
            let third = geo.size.width / 3
            NavigationSplitView(columnVisibility: $visibility) {
                lists(List(selection: $source) { rows })
                    .navigationSplitViewColumnWidth(third)
                    .toolbar(removing: .sidebarToggle)   // the lists always stay
            } content: {
                Group {
                    if let source {
                        TaskListScreen(source: source, opened: $task).id(source)
                    } else {
                        Text("Select a list").foregroundStyle(Color.subtle)
                    }
                }
                .navigationSplitViewColumnWidth(third)
            } detail: {
                Group {
                    // The stored task, so edits made in the details show in it.
                    if let opened = task, let current = store.tasks.first(where: { $0.id == opened.id || $0.id == store.adopted[opened.id] }) {
                        ScrollView { TaskDetails(task: current, close: { task = nil }).padding(20) }
                            .id(opened.id)   // fresh state per task, as in the drawer
                    } else {
                        Text("Select a task").foregroundStyle(Color.subtle)
                    }
                }
                .appToolbar()   // the eye at the top right, as in Calendar and Notes
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(of: visibility) { visibility = .all }   // iPadOS hides the first column on its own in some sizes
        }
        .onChange(of: start, initial: true) {
            if start == .dueNow { (planned, source) = (.dueNow, .planned) } else if source == nil { source = .planned }
        }
        .onChange(of: source) { task = nil }
    }

    private func lists(_ list: some View) -> some View {
        list
            .modifier(ListEditor(edit: $listEdit))
            .navigationTitle(store.isSignedIn ? "Tasks" : "Tasks (sample)")
            .refreshable { await store.refresh() }
    }

    @ViewBuilder private var rows: some View {
        Section {
            row("Planned", "calendar", .planned)
            row("Important", "star", .important)
            row("All", "tray.full", .all)
            ForEach(store.visibleLists.filter(\.isBuiltIn)) { row($0.name, $0.icon, .list($0.id)) }
        }
        Section("Lists") {
            ForEach(store.visibleLists.filter { !$0.isBuiltIn }) { list in
                NavigationLink(value: TaskSource.list(list.id)) {
                    Text(list.name).badge(store.tasks(in: .list(list.id)).count)
                }
                .swipeActions { ListActions(list: list, edit: $listEdit) }
            }
            .onMove { from, to in
                var shown = store.visibleLists.filter { !$0.isBuiltIn }
                shown.move(fromOffsets: from, toOffset: to)
                store.setListOrder(shown)
                showOrderNote = true
            }
            if showOrderNote { OrderNote(isShown: $showOrderNote) }
            Button("New List", systemImage: "plus") { listEdit = .new }
        }
    }

    private func row(_ name: String, _ icon: String, _ source: TaskSource) -> some View {
        NavigationLink(value: source) {
            Label(name, systemImage: icon).badge(store.tasks(in: source).count)
        }
    }
}

/// One view's or list's tasks. Tapping a task raises its details as a drawer from the bottom.
struct TaskListScreen: View {
    @Environment(AppStore.self) private var store
    let source: TaskSource
    var opened: Binding<TodoTask?>?   // iPad: the task opens beside the list instead of in a drawer
    @AppStorage("plannedFilter") private var planned = PlannedFilter.dueNow   // the last one used
    @State private var draft = ""
    @State private var ignored: Set<String> = []   // words in the draft the user said aren't a date or a star
    @State private var typing = false   // the add bar has the keyboard
    @State private var selected: TodoTask?
    @State private var added: [String] = []   // tasks added on this screen, shown last
    @AppStorage("taskSort") private var sort = TaskSort.list

    private var isSingleList: Bool {
        if case .list = source { true } else { false }
    }

    var body: some View {
        let today = Calendar.laes.startOfDay(for: .now)
        let tasks = store.sortedTasks(in: source, planned: planned, now: .now, by: sort, addedLast: added)
        ScrollViewReader { proxy in
            List {
                if source == .planned {
                    filters.listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                }
                // One flat list with the list's name in each row: sections per list cost too much space on a phone.
                ForEach(tasks) { task in
                    TaskListRow(task: task, today: today, showsList: !isSingleList, isSelected: opened?.wrappedValue?.id == task.id) {
                        if let opened { opened.wrappedValue = task } else { selected = task }
                    }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
                if tasks.isEmpty {
                    Text("Nothing here").foregroundStyle(Color.subtle).frame(maxWidth: .infinity).listRowSeparator(.hidden)
                }
            }
            .onChange(of: added) { _, ids in if let id = ids.last { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
        }
        .listStyle(.plain)
        .navigationTitle(store.title(of: source))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort by", selection: $sort) {
                        ForEach(TaskSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                if opened == nil {   // on iPad the eye sits over the details, at the top right
                    Button { store.showPrivate.toggle() } label: {
                        Label(store.showPrivate ? "Hide Private" : "Show Private", systemImage: store.showPrivate ? "eye" : "eye.slash")
                    }
                }
            }
        }
        .refreshable { await store.refresh() }
        .safeAreaInset(edge: .bottom) { if source != .important { addBar(today: today) } }
        .sheet(item: $selected) { opened in
            // The stored task, so edits made in the drawer show in it.
            let task = store.tasks.first { $0.id == opened.id || $0.id == store.adopted[opened.id] } ?? opened
            TaskDetails(task: task, close: { selected = nil })
                .id(opened.id)   // fresh state per task: a quick switch kept the old one's held edits and saved them to the new task
        }
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(PlannedFilter.allCases, id: \.self) { filter in
                    Button(filter.rawValue) { planned = filter }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(planned == filter ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(planned == filter ? Color.brand : Color.primary.opacity(0.07), in: Capsule())
                        .accessibilityAddTraits(planned == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    /// New tasks go to the open list (else To Do's default list); in Planned they are due on the filter's day.
    /// A day or "star" typed into the title is underlined, shown as a badge above, and applied instead.
    private func addBar(today: Date) -> some View {
        let quick = QuickAdd(draft, now: .now, ignoring: ignored)
        return HStack(spacing: 10) {
            Image(systemName: "plus").fontWeight(.semibold).foregroundStyle(Color.brandText)
            EntryField(prompt: source == .planned ? planned.addPrompt : "Add a task", text: $draft, isEditing: $typing) { add(today: today) }
                .overlay(alignment: .leading) { QuickAddUnderline(quick: quick, text: draft) }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .glassCapsule()
        .overlay(alignment: .top) {
            // Badges for the words read, and a way out of the keyboard: Return keeps it up for the next task.
            HStack(alignment: .bottom, spacing: 8) {
                QuickAddBadges(quick: quick, draft: draft, ignored: $ignored)
                Spacer(minLength: 0)
                if typing {
                    Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .glassCapsule()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .alignmentGuide(.top) { $0[.bottom] + 8 }   // above the bar without moving the list
            .animation(.snappy, value: typing)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func add(today: Date) {
        var listID: String?
        if case .list(let id) = source { listID = id }
        let quick = QuickAdd(draft, now: .now, ignoring: ignored)
        guard let task = store.addTask(quick, otherwise: source == .planned ? planned.newTaskDay(today: today) : nil, listID: listID) else { return }
        added.append(task.id)
        (draft, ignored) = ("", [])
    }
}
