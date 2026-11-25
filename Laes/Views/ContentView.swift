import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("showWelcome") private var showWelcome = true
    @AppStorage("mainView") private var mode = MainView.weeks
    private enum MainView: String { case weeks, tasks, notes }
    @State private var opened: Set<MainView> = []   // views shown once stay alive while hidden

    private var secondWeek: Date { Calendar.laes.date(byAdding: .day, value: 7, to: store.weekStart)! }

    private var title: String {
        let last = Calendar.laes.date(byAdding: .day, value: 13, to: store.weekStart)!
        return (store.weekStart..<last).formatted(.interval.day().month(.wide).year())
    }

    private var subtitle: String {
        let iso = Calendar(identifier: .iso8601)
        let week = { iso.component(.weekOfYear, from: Calendar.laes.date(byAdding: .day, value: $0, to: store.weekStart)!) }
        return "Weeks \(week(2))–\(week(9))"   // Mondays of both weeks
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                Divider()   // the toolbar's lower edge, in every view
                if let message = store.errorMessage {
                    errorBar(message)
                    Divider()
                }
                ZStack {
                    page(.weeks) {
                        VStack(spacing: 0) {
                            WeekRow(weekStart: store.weekStart, now: context.date)
                            Color.primary.opacity(0.28).frame(height: 2)   // heavier than the hairlines inside a week
                            WeekRow(weekStart: secondWeek, now: context.date)
                        }
                    }
                    page(.tasks) { TaskListView(now: context.date, isShown: mode == .tasks) }
                    page(.notes) { NotesView(isShown: mode == .notes) }
                }
            }
            .id([store.firstWeekday, store.firstHour, store.lastHour])   // the rows read these from defaults
        }
        .frame(minWidth: 1100, minHeight: 720)
        .navigationTitle(mode == .tasks ? "Tasks" : mode == .notes ? "Notes" : title)
        .navigationSubtitle(mode == .tasks ? "\(store.visibleTasks.count) open" : mode == .notes ? (store.visibleNotes.count == 1 ? "1 note" : "\(store.visibleNotes.count) notes") : subtitle)
        .onChange(of: store.openNote, initial: true) {
            if store.openNote != nil { mode = .notes }   // NotesView then selects it
        }
        .onChange(of: mode, initial: true) {
            opened.insert(mode)
            NSApp.keyWindow?.makeFirstResponder(nil)   // typing never goes on in a view that was just hidden
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showWelcome) { WelcomeView() }
        #if DEBUG
        .task { await switchViewsIfAsked() }
        #endif
    }

    #if DEBUG
    /// `-benchViews N`: switches away from the weeks and back N times, 0.4 s apart, then quits. Run it under
    /// Instruments' Time Profiler to compare how much main-thread work switching views takes.
    private func switchViewsIfAsked() async {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-benchViews"), index + 1 < args.count, let cycles = Int(args[index + 1]) else { return }
        try? await Task.sleep(for: .seconds(8))   // time to attach the profiler
        for cycle in 0..<cycles {
            mode = cycle.isMultiple(of: 2) ? .tasks : .notes
            try? await Task.sleep(for: .milliseconds(400))
            mode = .weeks
            try? await Task.sleep(for: .milliseconds(400))
        }
        NSApp.terminate(nil)
    }
    #endif

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $mode) {
                Label("Weeks", systemImage: "calendar").tag(MainView.weeks)
                Label("Tasks", systemImage: "checklist").tag(MainView.tasks)
                Label("Notes", systemImage: "note.text").tag(MainView.notes)
            }
            .pickerStyle(.segmented)
            .help("Switch between the weeks, all tasks and notes (⌘L)")
        }
        ToolbarItem(placement: .navigation) {
            Button("Next View") {
                // While a note is being edited, ⌘L makes a list there instead.
                if let editor = NSApp.keyWindow?.firstResponder as? MarkdownTextView, editor.isEditable { return editor.apply(.bulletList) }
                mode = mode == .weeks ? .tasks : mode == .tasks ? .notes : .weeks
            }
                .keyboardShortcut("l")
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // For the weeks, but always there and greyed out elsewhere: adding and removing them (or .hidden()) made AppKit
        // rebuild the toolbar on every switch, a third of its cost. Elsewhere their shortcuts are off, since ⌘← and ⌘→
        // belong to text editing.
        ToolbarItemGroup(placement: .navigation) {
            let weeks = mode == .weeks
            Group {
                Button { store.shiftWeeks(-1) } label: { Label("Previous Week", systemImage: "chevron.left") }
                    .keyboardShortcut(weeks ? KeyboardShortcut(.leftArrow) : nil)
                    .help("Previous week (⌘←)")
                Button("Today") { store.goToToday() }
                    .keyboardShortcut(weeks ? KeyboardShortcut("t") : nil)
                    .help("Go to this week (⌘T)")
                Button { store.shiftWeeks(1) } label: { Label("Next Week", systemImage: "chevron.right") }
                    .keyboardShortcut(weeks ? KeyboardShortcut(.rightArrow) : nil)
                    .help("Next week (⌘→)")
            }
            .disabled(!weeks)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if store.isOffline || !store.pending.isEmpty {
                let count = store.pending.count
                Label(store.isOffline ? (count == 0 ? "Offline" : "Offline · \(count) to send") : "Sending \(count)…",
                      systemImage: store.isOffline ? "wifi.slash" : "arrow.up.circle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(Color.subtle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .help(store.isOffline
                          ? "No connection. You're seeing the last synced data; task changes are saved and sent when you're back online."
                          : "Sending your task changes to Microsoft.")
            }

            Button { store.showPrivate.toggle() } label: {
                Label(store.showPrivate ? "Hide Private" : "Show Private", systemImage: store.showPrivate ? "eye" : "eye.slash")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help(store.showPrivate ? "Hide private items (⇧⌘P)" : "Show private items (⇧⌘P)")

            Button { Task { await store.refresh() } } label: {
                if store.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r")
            .disabled(store.isSyncing)
            .help(store.lastSync.map { "Last refreshed \($0.formatted(date: .omitted, time: .shortened)) · Refresh (⌘R)" } ?? "Refresh (⌘R)")

            if !store.isSignedIn {
                Text("Sample data")
                    .font(.caption)
                    .foregroundStyle(Color.subtle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .help("Showing demo content. Sign in to see your calendar and tasks.")
            }
            // Settings and account as one control, there whether signed in or not.
            ControlGroup {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (⌘,)")
                if store.isSignedIn {
                    Menu {
                        Button("Sign Out") { store.signOut() }
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                    .help("Account")
                } else {
                    Button("Sign In") { Task { await store.signIn() } }
                }
            }
        }
    }

    /// Once shown, a view stays alive while another is in front, so switching back doesn't build it all again
    /// (two weeks of meetings and tasks are hundreds of views). Hidden, it takes no clicks, and its text fields are
    /// disabled so neither typing nor Tab reaches them. (Disabling the whole view cost a third of every switch.)
    @ViewBuilder private func page(_ view: MainView, @ViewBuilder _ content: () -> some View) -> some View {
        if mode == view || opened.contains(view) {
            let shown = mode == view
            content()
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
        }
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.important)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.yellow.opacity(0.12))
        .accessibilityElement(children: .contain)
    }
}

