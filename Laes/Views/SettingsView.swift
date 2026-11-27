import BoringKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    /// Outlook's categories, any seen on loaded events, and whatever is already marked private.
    private var categories: [String] {
        Set(store.categoryColors.keys).union(store.events.flatMap(\.categories)).union(store.privateCategories)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private enum Pane: String, CaseIterable, Identifiable {
        #if os(macOS)
        case general = "General", privateGroup = "Private Group", icon = "App Icon", ai = "AI Access", about = "About & Legal"
        #else
        case general = "General", behavior = "Behavior", privateGroup = "Private Group", icon = "App Icon", about = "About & Legal"
        #endif
        var id: Self { self }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .privateGroup: "eye.slash"
            case .icon: "paintpalette"
            #if os(macOS)
            case .ai: "sparkles"
            #else
            case .behavior: "hand.tap"
            #endif
            case .about: "info.circle"
            }
        }
    }
    @State private var pane: Pane? = .general
    @State private var copiedPrompt = false
    @State private var showFeedback = false

    #if os(iOS)
    @AppStorage("tasksStart") private var tasksStart = TasksStart.lists
    @Environment(\.dismiss) private var dismiss   // shown as a sheet from the gear

    var body: some View {
        NavigationStack {
            Form {
                account
                Section {
                    ForEach(Pane.allCases) { pane in
                        NavigationLink {
                            page(pane).navigationTitle(pane.rawValue)
                        } label: {
                            Label(pane.rawValue, systemImage: pane.icon)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private var behavior: some View {
        Section {
            Picker("Tasks opens", selection: $tasksStart) {
                Text("Your lists").tag(TasksStart.lists)
                Text("Planned: Overdue & Today").tag(TasksStart.dueNow)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("The Tasks tab opens")
        } footer: {
            note("Planned then shows what's overdue or due today. Back leads to your lists.")
        }
    }
    #else
    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                .navigationSplitViewColumnWidth(190)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            page(pane ?? .general).navigationTitle((pane ?? .general).rawValue)
        }
        .frame(width: 720, height: 520)
    }
    #endif

    @ViewBuilder private func page(_ pane: Pane) -> some View {
        switch pane {
        case .icon: IconEditor()
        #if os(macOS)
        case .general: form { account; general }
        case .ai: form { ai }
        #else
        case .general: form { general }
        case .behavior: form { behavior }
        #endif
        case .privateGroup: form { privateGroup }
        case .about: form { about }
        }
    }

    private func form(@ViewBuilder _ content: () -> some View) -> some View {
        Form(content: content).formStyle(.grouped)
    }

    /// On the Mac at the top of General, on iPhone above the panes.
    @ViewBuilder private var account: some View {
        Section("Account") {
            LabeledContent(store.isSignedIn ? "Signed in with Microsoft" : "Not signed in") {
                if store.isSignedIn {
                    Button("Sign Out") { store.signOut() }
                } else {
                    Button("Sign In") { Task { await store.signIn() } }
                }
            }
        }
    }

    @ViewBuilder private var general: some View {
        Section {
            Toggle("Keep notes in OneDrive", isOn: Binding(get: { store.notesEnabled }, set: { on in
                if on, store.isSignedIn { Task { await store.enableNotes() } } else { store.notesEnabled = on }
            }))
        } footer: {
            note("Notes are Markdown files in a OneDrive folder only lães uses. Switch this off if your account has no OneDrive or your organisation doesn't allow it; signing in then no longer asks for it.")
        }
        Section {
            LabeledContent("Meeting reminders") { ReminderPermission() }
        } footer: {
            note("Five minutes before a meeting that has notes, lães shows them in a notification, including notes an AI tool wrote for it.")
        }
        Section("Week") {
            @Bindable var store = store
            Picker("Week starts on", selection: $store.firstWeekday) {
                ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
            }
            Picker("Day starts at", selection: $store.firstHour) {
                ForEach(0...12, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            Picker("Day ends at", selection: $store.lastHour) {
                ForEach(13...24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
        }
    }

    @ViewBuilder private var privateGroup: some View {
        Section {
            note("The private group is what you'd rather not have on screen, say when you share your screen or show someone your calendar: meetings in the calendar categories and tasks on the lists you pick below. The eye button hides or shows the whole group at once. Hidden meetings stay on the calendar as plain blocks, so you still see the time is taken; hidden tasks and notes disappear. Nothing changes in Microsoft 365.")
        }
        Section("Calendar categories") {
            ForEach(categories, id: \.self) { name in
                Toggle(name, isOn: binding(\.privateCategories, name))
            }
        }
        Section("Task lists") {
            ForEach(store.taskLists) { list in
                Toggle(list.name, isOn: binding(\.privateListIDs, list.id))
            }
        }
    }

    #if os(macOS)
    private var connectCommand: String {
        "claude mcp add --transport http laes \(MCPServer.url) --header \"Authorization: Bearer \(MCPServer.token)\""
    }

    /// Pasted into an AI tool, this makes it add the server itself.
    private var setupPrompt: String {
        """
        Connect to my lães app, which gives you my Microsoft 365 calendar, Microsoft To Do tasks and Markdown notes over MCP.

        Add this MCP server to your own configuration:
        - Name: laes
        - Transport: Streamable HTTP
        - URL: \(MCPServer.url)
        - Header: Authorization: Bearer \(MCPServer.token)

        If you are Claude Code, run:
        \(connectCommand)

        The server only runs while the lães app is open on this Mac. When you are connected, call list_task_lists to confirm it works and tell me what you can now do. Treat the token as a secret and don't repeat it.
        """
    }

    @ViewBuilder private var ai: some View {
        Section {
            @Bindable var store = store
            Button(store.mcpEnabled ? "Copy Setup Prompt" : "Turn On and Copy Setup Prompt") {
                store.mcpEnabled = true
                copy(setupPrompt)
                copiedPrompt = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
            if copiedPrompt {
                Label("Copied. Paste it into your AI tool and it will connect itself.", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.subtle)
            }
        }
        Section {
            @Bindable var store = store
            Toggle("Let AI tools on this Mac connect", isOn: $store.mcpEnabled)
            if let error = store.mcpError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.overdue)
            }
        } footer: {
            note("Runs an MCP server that only this Mac can reach, while lães is open. A connected tool can read your calendar, tasks and notes, add and change tasks and notes, and block time. Items hidden with the eye button are hidden from it too, including the notes of private meetings.")
        }
        if store.mcpEnabled {
            Section {
                LabeledContent("Address", value: MCPServer.url).textSelection(.enabled)
                LabeledContent("Port") {
                    // Not the system ports below 1024.
                    TextField("Port", value: Binding(get: { store.mcpPort }, set: { store.mcpPort = min(max($0, 1024), 65535) }),
                              format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Button("Random") { store.mcpPort = Int.random(in: 10000...49151) }
                        .help("Pick another port if this one is taken")
                    Button("Default") { store.mcpPort = MCPServer.defaultPort }
                        .disabled(store.mcpPort == MCPServer.defaultPort)
                }
                LabeledContent("Claude Code") { Button("Copy Command") { copy(connectCommand) } }
                LabeledContent("Other tools") { Button("Copy Access Token") { copy(MCPServer.token) } }
            } header: {
                Text("Connect")
            } footer: {
                note("For Claude Code, paste the command into a terminal. Other tools need the address and the token as an \"Authorization: Bearer\" header. Treat the token like a password. After changing the port, connect your tools again: the address they saved no longer works.")
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    #endif

    @ViewBuilder private var about: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            LabeledContent("Copyright", value: "© 2026 Julian Krenge")
        }
        Section {
            Button("Send Feedback…") { showFeedback = true }
                .sheet(isPresented: $showFeedback) { FeedbackView() }
        } footer: {
            note("Goes to the developer of lães, with the app version and your device model. Add your email only if you'd like a reply.")
        }
        Section("Your data") {
            note("Your calendar, tasks and notes go only to Microsoft, using your own sign-in. Notes, if you turn them on, are files in your own OneDrive. Everything is kept on this device for offline use, and the sign-in is stored in your Keychain. Signing out removes the local copy.")
            note("lães sends crash reports and anonymous usage counts, such as how often a task is added, to its developer's own server. They hold nothing from your calendar, tasks or notes, and they aren't linked to you or your Microsoft account.")
        }
        Section("Third-party software") {
            note("lães is built with Apple's system frameworks and three open-source libraries for crash reports and usage counts: BoringKit, KSCrash and the Aptabase Swift client, all under the MIT licence. Icons are Apple's SF Symbols.")
        }
        Section("Trademarks") {
            note("lães is an independent app and is not affiliated with or endorsed by Microsoft. Microsoft 365, Outlook and Microsoft To Do are trademarks of the Microsoft group of companies.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
    }

    private func binding(_ set: ReferenceWritableKeyPath<AppStore, Set<String>>, _ value: String) -> Binding<Bool> {
        Binding(
            get: { store[keyPath: set].contains(value) },
            set: { if $0 { store[keyPath: set].insert(value) } else { store[keyPath: set].remove(value) } }
        )
    }
}

/// Whether notifications are allowed, since reminders silently do nothing without them; a way to allow them if not.
private struct ReminderPermission: View {
    @State private var status: UNAuthorizationStatus?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch status {
            case .authorized, .provisional, .ephemeral: Text("On").foregroundStyle(Color.subtle)
            case .notDetermined:
                Button("Allow") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        await refresh()
                    }
                }
            case .denied:
                Button("Turn On in Settings") { open(Self.settingsURL) }
            default: ProgressView().controlSize(.small)
            }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { Task { await refresh() } }   // back from System Settings
    }

    private func refresh() async { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }

    #if os(macOS)
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.laes.Laes")!
    private func open(_ url: URL) { NSWorkspace.shared.open(url) }
    #else
    private static let settingsURL = URL(string: UIApplication.openNotificationSettingsURLString)!
    private func open(_ url: URL) { UIApplication.shared.open(url) }
    #endif
}
