import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("showWelcome") private var showWelcome = true
    @AppStorage("mainView") private var mode = MainView.weeks
    @AppStorage("appearance") private var appearance = Appearance.system
    private enum MainView: String { case weeks, tasks, notes }
    @State private var opened: Set<MainView> = []   // views shown once stay alive while hidden
    @State private var commandHeld = false   // held a moment: the toolbar shows its shortcuts
    @State private var holdMonitor: Any?
    @State private var search = SearchModel()
    private var searchFirst: SearchResults.Kind { mode == .tasks ? .tasks : mode == .notes ? .notes : .meetings }

    private var secondWeek: Date { Calendar.laes.date(byAdding: .day, value: 7, to: store.weekStart)! }

    private var title: String {
        let last = Calendar.laes.date(byAdding: .day, value: 13, to: store.weekStart)!
        return (store.weekStart..<last).formatted(.interval.day().month(.abbreviated).year())   // short: the search has the middle
    }

    private var subtitle: String {
        let iso = Calendar(identifier: .iso8601)
        let week = { iso.component(.weekOfYear, from: Calendar.laes.date(byAdding: .day, value: $0, to: store.weekStart)!) }
        return "Weeks \(week(2))–\(week(9))"   // Mondays of both weeks
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                if mode == .weeks { Divider() }   // the toolbar's lower edge; Tasks and Notes sit on cards instead
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
                        .background(Color(nsColor: .windowBackgroundColor))   // the grid keeps its colour below that toolbar
                    }
                    page(.tasks) { TaskListView(now: context.date, isShown: mode == .tasks) }
                    page(.notes) { NotesView(isShown: mode == .notes) }
                }
                .overlay { SearchPanel(model: search, first: searchFirst, now: context.date, open: open) }
            }
            .background { Color.canvas.ignoresSafeArea() }   // one background, under the toolbar too
            .id([store.firstWeekday, store.firstHour, store.lastHour])   // the rows read these from defaults
        }
        .frame(minWidth: 1100, minHeight: 720)
        // Tasks and Notes name themselves on their cards: their toolbar shows no title, but the window keeps one
        // (VoiceOver, the Window menu, Mission Control).
        .navigationTitle(mode == .tasks ? "Tasks" : mode == .notes ? "Notes" : title)
        .navigationSubtitle(mode == .weeks ? subtitle : "")
        .toolbar(removing: mode == .weeks ? nil : .title)
        .onChange(of: store.openNote, initial: true) {
            if store.openNote != nil { mode = .notes }   // NotesView then selects it
        }
        .onChange(of: mode, initial: true) {
            opened.insert(mode)
            NSApp.keyWindow?.makeFirstResponder(nil)   // typing never goes on in a view that was just hidden
        }
        .onChange(of: appearance, initial: true) { NSApp.appearance = appearance.nsAppearance }
        .toolbar { toolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background { shortcuts }
        .onAppear {
            watchCommandKey()
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments   // for screenshots
            if args.contains("-holdCommand") { commandHeld = true }
            if let index = args.firstIndex(of: "-searchFor"), index + 1 < args.count { search.query = args[index + 1] }
            if args.contains("-pressFind") {   // ⌘F as the keyboard sends it; says where the typing then goes
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let window = NSApp.windows.filter(\.isVisible).max(by: { $0.frame.width < $1.frame.width }),
                          let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3) else { return }
                    window.makeKey()
                    let handled = window.performKeyEquivalent(with: key) ? "window" : NSApp.mainMenu?.performKeyEquivalent(with: key) == true ? "menu" : "nobody"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let responder = window.firstResponder
                        let field = (responder as? NSTextView)?.delegate as? NSTextField
                        let inToolbar = field.map { $0.convert($0.bounds, to: nil).minY >= window.contentLayoutRect.maxY } ?? false
                        FileHandle.standardError.write(Data("pressFind: handled by \(handled); typing goes to \(responder.map { String(describing: type(of: $0)) } ?? "nothing"), in the toolbar: \(inToolbar)\n".utf8))
                    }
                }
            }
            #endif
        }
        .onDisappear { holdMonitor.map(NSEvent.removeMonitor); holdMonitor = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in commandHeld = false }
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
                Label("Weeks", systemImage: "calendar").tag(MainView.weeks).help("Weeks (⌘1)")
                Label("Tasks", systemImage: "checklist").tag(MainView.tasks).help("Tasks (⌘2)")
                Label("Notes", systemImage: "note.text").tag(MainView.notes).help("Notes (⌘3)")
            }
            .pickerStyle(.segmented)
            .help("Weeks (⌘1), Tasks (⌘2), Notes (⌘3), or the next one (⌘L)")
            .overlay(alignment: .bottom) {
                if commandHeld {
                    HStack(spacing: 0) { ForEach(["⌘1", "⌘2", "⌘3"], id: \.self) { hint($0).frame(maxWidth: .infinity) } }
                        .offset(y: 17)
                }
            }
        }
        // Only in the weeks. Kept invisible elsewhere, they still left their empty glass circles; adding and removing
        // them costs a toolbar rebuild on each switch to or from the weeks.
        if mode == .weeks {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 2) {   // one control: back, today, forward. (A ControlGroup lands right of the search.)
                    // While the search holds text, ⌘← and ⌘→ belong to it.
                    Button { store.shiftWeeks(-1) } label: { Label("Previous Week", systemImage: "chevron.left") }
                        .keyboardShortcut(search.hasText ? nil : KeyboardShortcut(.leftArrow))
                        .help("Previous week (⌘←)")
                    Button("Today") { store.goToToday() }
                        .keyboardShortcut("t")
                        .help("Go to this week (⌘T)")
                    Button { store.shiftWeeks(1) } label: { Label("Next Week", systemImage: "chevron.right") }
                        .keyboardShortcut(search.hasText ? nil : KeyboardShortcut(.rightArrow))
                        .help("Next week (⌘→)")
                }
            }
        }
        ToolbarItem(placement: .principal) {
            SearchField(model: search, first: searchFirst, open: open)
        }
        // Status, not buttons: the badges alone, without the toolbar's glass around them.
        ToolbarItem(placement: .primaryAction) {
          HStack(spacing: 6) {
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

            // Not in the pictures taken for the site (-shot).
            if !store.isSignedIn, !ProcessInfo.processInfo.arguments.contains("-shot") {
                Text("Sample data")
                    .font(.caption)
                    .foregroundStyle(Color.subtle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .help("Showing demo content. Sign in to see your calendar and tasks.")
            }
          }
        }
        .withoutGlass()
        // Refresh, settings and account as one control, there whether signed in or not.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
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
        // Private items on their own, rightmost, as on iPhone.
        ToolbarItem(placement: .primaryAction) {
            Button { store.showPrivate.toggle() } label: {
                Label(store.showPrivate ? "Hide Private" : "Show Private", systemImage: store.showPrivate ? "eye" : "eye.slash")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help(store.showPrivate ? "Hide private items (⇧⌘P)" : "Show private items (⇧⌘P)")
            .overlay(alignment: .bottom) { if commandHeld { hint("⇧⌘P").fixedSize().offset(y: 17) } }
        }
    }

    private func hint(_ keys: String) -> some View {
        Keycap(keys).background(Color.card, in: RoundedRectangle(cornerRadius: 5, style: .continuous))   // readable over the content below
    }

    /// Shortcuts without a button of their own. Kept out of the toolbar, where even hidden items take room.
    private var shortcuts: some View {
        HStack {
            Button("Weeks") { mode = .weeks }.keyboardShortcut("1")
            Button("Tasks") { mode = .tasks }.keyboardShortcut("2")
            Button("Notes") { mode = .notes }.keyboardShortcut("3")
            Button("Next View") {
                // While a note is being edited, ⌘L makes a list there instead.
                if let editor = NSApp.keyWindow?.firstResponder as? MarkdownTextView, editor.isEditable { return editor.apply(.bulletList) }
                mode = mode == .weeks ? .tasks : mode == .tasks ? .notes : .weeks
            }
            .keyboardShortcut("l")
            Button("Search") { SearchField.focus() }.keyboardShortcut("f")
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Shows what the search found: a task in Tasks, a note in Notes, a meeting in its week.
    private func open(_ hit: SearchResults.Hit) {
        switch hit.target {
        case .task(let id): (mode, store.openTask) = (.tasks, id)
        case .note(let name): store.openNote = name   // switches to Notes, as a reminder does
        case .event(let event):
            mode = .weeks
            store.show(event: event)
        }
        (search.query, search.isShown) = ("", false)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// ⌘ held for a moment, with nothing pressed after it, shows the toolbar's shortcuts under its buttons.
    private func watchCommandKey() {
        guard holdMonitor == nil else { return }
        var pending: DispatchWorkItem?
        holdMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            pending?.cancel()
            let held = event.type == .flagsChanged && event.modifierFlags.contains(.command)
            if held {
                let show = DispatchWorkItem {
                    // Still held, still here (⌘-Tab leaves without a key-up), and not over a note's own shortcut pill.
                    let editing = (NSApp.keyWindow?.firstResponder as? MarkdownTextView)?.isEditable == true
                    if NSApp.isActive, NSEvent.modifierFlags.contains(.command), !editing { commandHeld = true }
                }
                pending = show
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: show)
            } else {
                commandHeld = false
            }
            return event
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

/// Light, dark, or as the system is (the default). Settings › General.
enum Appearance: String, CaseIterable {
    case system, light, dark
    var title: String { self == .system ? "Automatic" : rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder func withoutGlass() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}
