import SwiftUI

/// One week: day header, a to-do slot per day, all-day strip and 07–20 time grid.
struct WeekRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    let weekStart: Date
    let now: Date

    static let gutter: CGFloat = 40
    static let laneHeight: CGFloat = 18
    private let cal = Calendar.laes

    private var days: [Date] { (0..<7).map { cal.date(byAdding: .day, value: $0, to: weekStart)! } }
    private var hairline: CGFloat { 1 / displayScale }

    var body: some View {
        GeometryReader { geo in
            let colW = (geo.size.width - Self.gutter) / 7
            VStack(spacing: 0) {
                header(colW).frame(height: 30)
                Divider()
                todoRow(colW).frame(height: CGFloat(todoRows) * (Metrics.taskRow + 1) + 8)
                Divider()
                allDayStrip(colW).frame(height: 2 * Self.laneHeight + 4)
                Divider()
                timeGrid(colW)
            }
            .background(alignment: .topLeading) { columnBackground(colW) }
        }
    }

    /// The to-do strip is as tall as the week's busiest day plus one free row to click in, capped at `maxRows`.
    private var todoRows: Int {
        let busiest = days.map { tasksDue(on: $0, from: store.visibleTasks, today: now).count }.max() ?? 0
        return min(TodoSlot.maxRows, busiest + 1)
    }

    // MARK: Sections

    private func columnBackground(_ colW: CGFloat) -> some View {
        // All-day events tint their whole day column. Ones drawn without a fill (free) or struck
        // through (cancelled, declined) don't, matching how their bar looks.
        let tints = allDayBars(store.calendarEvents, weekStart: weekStart).filter {
            $0.event.showAs != .free && !$0.event.isCancelled && $0.event.response != .declined && !$0.event.isRedacted
        }
        return HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter)
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                ZStack {
                    cal.isDateInWeekend(day) ? Color.primary.opacity(0.03) : Color.clear
                    if cal.isDate(day, inSameDayAs: now) { Color.brand.opacity(0.05) }
                    ForEach(tints.filter { $0.startColumn <= index && index < $0.endColumn }, id: \.event.id) { bar in
                        store.color(for: bar.event).opacity(0.10)
                    }
                }
                    .frame(width: colW)
                    .overlay(alignment: .leading) { Color.separator.frame(width: hairline) }
            }
        }
    }

    private func header(_ colW: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter)
            ForEach(days, id: \.self) { day in
                let isToday = cal.isDate(day, inSameDayAs: now)
                HStack(spacing: 5) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .foregroundStyle(isToday ? Color.primary : Color.subtle)
                    Text(day.formatted(.dateTime.day()))
                        .monospacedDigit()
                        .fontWeight(isToday ? .semibold : .regular)
                        .foregroundStyle(isToday ? Color.white : Color.primary)
                        .frame(minWidth: 20, minHeight: 20)
                        .background { if isToday { Capsule().fill(Color.brand) } }
                }
                .font(.system(size: 12, weight: isToday ? .semibold : .regular))
                .padding(.leading, 8)
                .frame(width: colW, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel((isToday ? "Today, " : "") + day.formatted(date: .complete, time: .omitted))
                .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private func allDayStrip(_ colW: CGFloat) -> some View {
        let bars = allDayBars(store.calendarEvents, weekStart: weekStart)
        let overflow = (bars.map(\.lane).max() ?? 0) >= 2
        let visibleLanes = overflow ? 1 : 2
        return ZStack(alignment: .topLeading) {
            ForEach(bars.filter { $0.lane < visibleLanes }, id: \.event.id) { bar in
                EventBlock(event: bar.event, color: store.color(for: bar.event),
                           size: CGSize(width: CGFloat(bar.endColumn - bar.startColumn) * colW - 4, height: Self.laneHeight - 2))
                    .offset(x: Self.gutter + CGFloat(bar.startColumn) * colW + 2, y: 3 + CGFloat(bar.lane) * Self.laneHeight)
            }
            if overflow {
                ForEach(0..<7, id: \.self) { day in
                    let hidden = bars.filter { $0.lane >= visibleLanes && $0.startColumn <= day && day < $0.endColumn }
                    if !hidden.isEmpty {
                        Text("+\(hidden.count) more")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.subtle)
                            .help(hidden.map { $0.event.isRedacted ? "Private" : $0.event.title }.joined(separator: "\n"))
                            .offset(x: Self.gutter + CGFloat(day) * colW + 8, y: 4 + Self.laneHeight)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func timeGrid(_ colW: CGFloat) -> some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .topLeading) {
                ForEach(DayHours.firstHour + 1 ..< DayHours.lastHour, id: \.self) { hour in
                    let y = CGFloat(hour - DayHours.firstHour) / CGFloat(DayHours.lastHour - DayHours.firstHour) * height
                    Color.separator.opacity(0.6)
                        .frame(height: hairline)
                        .padding(.leading, Self.gutter)
                        .offset(y: y)
                    Text(String(format: "%02d", hour))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.subtle)
                        .frame(width: Self.gutter - 8, alignment: .trailing)
                        .offset(y: y - 6)
                        .accessibilityHidden(true)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    DayGrid(day: day, width: colW, height: height)
                        .offset(x: Self.gutter + CGFloat(index) * colW)
                }
                if let index = days.firstIndex(where: { cal.isDate($0, inSameDayAs: now) }) {
                    let y = DayHours.y(for: now, dayStart: days[index], height: height)
                    if y >= 0, y <= height {
                        HStack(spacing: 0) {
                            Circle().frame(width: 7, height: 7)
                            Rectangle().frame(height: 1.5)
                        }
                        .foregroundStyle(.red)
                        .frame(width: colW + 3.5)
                        .offset(x: Self.gutter + CGFloat(index) * colW - 3.5, y: y - 3.5)
                        .accessibilityHidden(true)
                    }
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .topLeading)
        }
        .clipped()
    }

    private func todoRow(_ colW: CGFloat) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "checklist")
                .font(.system(size: 11))
                .foregroundStyle(Color.subtle)
                .frame(width: Self.gutter)
                .padding(.top, 7)
                .frame(maxHeight: .infinity, alignment: .top)
                .help("Tasks due")
                .accessibilityLabel("Tasks")
            ForEach(days, id: \.self) { day in
                TodoSlot(day: day, now: now).frame(width: colW)
            }
        }
    }

}

/// One day's tasks. Dropping a task here changes its due date to this day; clicking empty space
/// starts a new task. A full slot has no empty space, so its list ends with an "Add task" row instead.
struct TodoSlot: View {
    @Environment(AppStore.self) private var store
    let day: Date
    let now: Date
    @State private var isTargeted = false
    @State private var draft: String?   // non-nil while typing a new task
    @FocusState private var draftFocused: Bool

    static let maxRows = 4

    var body: some View {
        let tasks = tasksDue(on: day, from: store.visibleTasks, today: now)
        let isFull = tasks.count >= Self.maxRows
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(tasks) { task in
                        TaskRow(task: task, isOverdue: task.due! < Calendar.laes.startOfDay(for: now))
                    }
                    if draft != nil { draftField } else if isFull { addButton }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.brand.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { draft = "" }
        .dropDestination(for: String.self) { ids, _ in
            ids.forEach { store.move(taskID: $0, to: day) }
            return !ids.isEmpty
        } isTargeted: { isTargeted = $0 }
        .accessibilityAction(named: "Add task") { draft = "" }
    }

    private var draftField: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(Color.subtle)
            TextField("New task", text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: Metrics.taskFont))
                .focused($draftFocused)
                .onSubmit {
                    store.addTask(title: draft ?? "", due: day)
                    draft = nil
                }
                #if os(macOS)
                .onExitCommand { draft = nil }
                #endif
        }
        .frame(height: Metrics.taskRow)
        .padding(.horizontal, 8)
        // Focus only takes once the field is in the window, one runloop turn after it appears.
        .onAppear { DispatchQueue.main.async { draftFocused = true } }
        .onChange(of: draftFocused) { _, focused in if !focused { draft = nil } }
    }

    private var addButton: some View {
        Button { draft = "" } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 9))
                Text("Add task").font(.system(size: Metrics.taskFont))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.subtle)
            .frame(height: Metrics.taskRow)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TaskRow: View {
    @Environment(AppStore.self) private var store
    let task: TodoTask
    let isOverdue: Bool
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(Color.subtle)
            Text(task.title)
                .font(.system(size: Metrics.taskFont))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isOverdue, let due = task.due {
                Text(due.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.overdue)
                    .fixedSize()
            }
            if task.recurrence != nil {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.subtle)
            }
            if task.isImportant {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.important)
            }
        }
        .frame(height: Metrics.taskRow)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { showDetails = true }
        .draggable(task.id)
        .contextMenu { TaskActions(task: task) }
        .popover(isPresented: $showDetails) {
            TaskDetails(task: task)
        }
        .help(task.listName)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showDetails = true }
        .accessibilityLabel([
            task.title,
            task.listName,
            isOverdue ? task.due.map { "overdue since \($0.formatted(date: .abbreviated, time: .omitted))" } : nil,
            task.isImportant ? "important" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Popover for a task: details, subtasks and notes, with a button to tick it off under the title.
struct TaskDetails: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: TodoTask
    var close: (() -> Void)?   // set when shown in a panel instead of a popover
    @State private var newStep = ""
    @State private var editedNotes: String?   // nil until the user types
    @State private var editingNotes = false   // otherwise a non-empty note is shown formatted
    @State private var title = ""
    @State private var due: Date?   // sent when the details close: moving the task to another day closes them
    @State private var dueEdited = false
    @FocusState private var notesFocused: Bool
    @FocusState private var titleFocused: Bool

    /// The task as it is now: edits made here land in the store, not in `task`.
    /// Moving to another list gives the task a new id, which `adopted` maps to.
    private var current: TodoTask { store.tasks.first { $0.id == (store.adopted[task.id] ?? task.id) } ?? task }
    private var today: Date { Calendar.laes.startOfDay(for: .now) }
    private var isOverdue: Bool { due.map { $0 < today } ?? false }
    private var movableLists: [TaskList] { store.visibleLists.filter { !$0.isFlagged } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($titleFocused)
                .onSubmit(saveTitle)
                .onChange(of: titleFocused) { _, focused in if !focused { saveTitle() } }
            Button {
                saveNotes()
                store.complete(current)
                if let close { close() } else { dismiss() }
            } label: {
                Label("Mark as Completed", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
            .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 8) {
                field("list.bullet") {
                    if store.taskLists.first(where: { $0.id == current.listID })?.isFlagged == true {   // flagged emails stay put
                        Text(current.listName).padding(.leading, controlInset)
                    } else {
                        let target = store.moving[current.id]
                        Picker("List", selection: Binding(get: { target ?? current.listID }, set: { id in
                            guard let list = movableLists.first(where: { $0.id == id }) else { return }
                            saveEdits()
                            Task { await store.moveTask(current, to: list) }
                        })) {
                            ForEach(movableLists) { Text($0.name).tag($0.id) }
                        }
                        .buttonStyle(.borderless)
                        .fixedSize()
                        .disabled(target != nil)
                        if target != nil { ProgressView().controlSize(.small).accessibilityLabel("Moving") }
                    }
                }
                field("calendar", tint: isOverdue ? .overdue : nil) {
                    if let shown = due {
                        DatePicker("Due", selection: Binding(get: { shown }, set: { editDue(Calendar.laes.startOfDay(for: $0)) }),
                                   displayedComponents: .date)
                        clear("Remove due date") { editDue(nil) }
                        if isOverdue { Text("Overdue").foregroundStyle(Color.overdue) }
                    } else {
                        Button("Add due date") { editDue(today) }.buttonStyle(.borderless).padding(.leading, controlInset)
                    }
                }
                field("bell") {
                    if let reminder = current.reminder {
                        DatePicker("Remind me", selection: Binding(get: { reminder }, set: { store.setReminder(current, $0) }))
                        clear("Remove reminder") { store.setReminder(current, nil) }
                    } else {
                        Button("Remind me") { store.setReminder(current, suggestedReminder) }.buttonStyle(.borderless).padding(.leading, controlInset)
                    }
                }
                field("arrow.triangle.2.circlepath") {
                    Picker("Repeat", selection: Binding(get: { current.repeats?.unit }, set: { unit in
                        store.setRepeat(current, unit.map { RepeatRule(unit: $0, interval: current.repeats?.unit == $0 ? current.repeats!.interval : 1) })
                    })) {
                        Text("Doesn't repeat").tag(RepeatRule.Unit?.none)
                        ForEach(RepeatRule.Unit.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    if let rule = current.repeats, rule.unit != .weekdays {
                        Text(rule.every).foregroundStyle(Color.subtle).accessibilityHidden(true)
                        Stepper(rule.every, value: Binding(get: { rule.interval }, set: { store.setRepeat(current, RepeatRule(unit: rule.unit, interval: $0)) }), in: 1...99)
                            .fixedSize()
                    }
                }
                Button { store.setImportant(current, !current.isImportant) } label: {
                    field(current.isImportant ? "star.fill" : "star", tint: current.isImportant ? .important : nil) {
                        Text(current.isImportant ? "Important" : "Mark as important").padding(.leading, controlInset)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current.isImportant ? .isSelected : [])
            }
            .labelsHidden()
            .datePickerStyle(.compact)
            .environment(\.calendar, .laes)   // weeks start on the user's day, as in the calendar
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.checklists[current.id] ?? []) { step in
                    StepRow(step: step, toggle: { store.toggleStep(step, in: current) }, rename: { store.renameStep(step, to: $0, in: current) })
                }
                HStack(spacing: 6) {
                    Image(systemName: "plus").foregroundStyle(Color.subtle).frame(width: 16)
                    Group {
                        #if os(iOS)
                        EntryField(prompt: "Add step", text: $newStep, style: .callout, onReturn: addStep)
                        #else
                        TextField("Add step", text: $newStep, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .onSubmit(addStep)
                        #endif
                    }
                    .padding(.leading, controlInset)
                }
            }
            Divider()
            if current.notesReadOnly {
                ScrollView { Text(current.notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 90)
                    .help("This note has formatting from Outlook, so it can only be edited there.")
            } else if !editingNotes, !(editedNotes ?? current.notes).isEmpty {
                Text(renderMarkdown(editedNotes ?? current.notes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: editNotes)
                    .help("Click to edit. Markdown is formatted.")
                    .accessibilityAction(named: "Edit note", editNotes)
            } else {
                TextEditor(text: Binding(get: { editedNotes ?? current.notes }, set: { editedNotes = $0 }))
                    .focused($notesFocused)
                    .onChange(of: notesFocused) { _, focused in editingNotes = focused }
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .padding(.horizontal, -5)   // TextEditor insets its text; align it with the labels
                    .frame(height: editingNotes ? 140 : 72)
                    .overlay(alignment: .topLeading) {
                        if (editedNotes ?? current.notes).isEmpty {
                            Text("Add note").foregroundStyle(Color.subtle).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Note")
            }
        }
        .font(.callout)
        .padding(16)
        .detailsFrame(width: 320)
        .task { await store.loadChecklist(for: current) }
        .onAppear { (title, due) = (current.title, current.due) }
        .onChange(of: current.due) { _, new in if !dueEdited { due = new } }   // a repeat can set it
        .onDisappear(perform: saveEdits)
    }

    private func addStep() {
        guard !newStep.trimmingCharacters(in: .whitespaces).isEmpty else { return }   // an empty Return ends adding
        store.addStep(newStep, to: current)
        newStep = ""
    }

    /// Sends what is still held here: the due date, title and note.
    private func saveEdits() {
        if dueEdited { store.setDue(current, due) }
        dueEdited = false
        saveTitle()
        saveNotes()
    }

    /// An icon column lined up with the steps and notes below, then the field.
    private func field(_ icon: String, tint: Color? = nil, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint ?? Color.subtle).frame(width: 16)
            content()
        }
        .frame(minHeight: 22)
    }

    private func clear(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.subtle) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .help(label)
    }

    /// 9:00 on the due day (or today); the next full hour if that has passed.
    private var suggestedReminder: Date {
        let cal = Calendar.laes
        let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: max(current.due ?? today, today))!
        return morning > .now ? morning : cal.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)!
    }

    private func editDue(_ day: Date?) {
        due = day
        dueEdited = true
    }

    private func saveTitle() {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = current.title } else { store.rename(current, to: title) }
    }

    private func editNotes() {
        editingNotes = true
        DispatchQueue.main.async { notesFocused = true }   // the editor exists one runloop turn later
    }

    private func saveNotes() {
        if let editedNotes { store.setNotes(current, editedNotes) }
        editedNotes = nil
    }
}

/// Pickers and date fields draw their text this far inside their frame; plain text beside the same icons
/// is moved in to match, so every label in the details starts on one line.
#if os(macOS)
let controlInset: CGFloat = 4
#else
let controlInset: CGFloat = 12
#endif

/// The circle in front of a task: shows a tick on hover and completes the task.
struct CompleteButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: hovering ? "checkmark.circle" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(hovering ? Color.brandText : Color.subtle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Mark as Completed")
        .accessibilityLabel("Mark \(title) as completed")
    }
}

/// A subtask: the circle ticks it off, the title is an inline field for renaming.
struct StepRow: View {
    let step: ChecklistItem
    let toggle: () -> Void
    let rename: (String) -> Void
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: toggle) {
                Image(systemName: step.isChecked ? "checkmark.circle.fill" : "circle").frame(width: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step.isChecked ? "Mark \(step.title) as not completed" : "Mark \(step.title) as completed")
            Group {
                #if os(macOS)
                // A vertical field wraps long steps and keeps the text in place when it takes focus.
                TextField("Step", text: $title, axis: .vertical).lineLimit(1...6)
                #else
                TextField("Step", text: $title)
                #endif
            }
                .textFieldStyle(.plain)
                .padding(.leading, controlInset)
                .strikethrough(step.isChecked)
                .foregroundStyle(step.isChecked ? Color.subtle : Color.primary)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
        .onAppear { title = step.title }
        .onChange(of: step.title) { _, new in title = new }
        .onDisappear(perform: commit)
    }

    private func commit() {
        let new = title.trimmingCharacters(in: .whitespaces)
        if new.isEmpty { title = step.title } else if new != step.title { rename(new) }
    }
}
