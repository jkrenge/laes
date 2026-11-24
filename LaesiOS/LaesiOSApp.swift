import BackgroundTasks
import SwiftUI

@main
struct LaesiOSApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    private static let refreshTask = "app.laes.Laes.refresh"   // also in Info.plist

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Color.brandText)
                // iOS stops the app in the background: sync when it comes back, and ask to be woken now and then meanwhile.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { Task { await store.refreshIfStale() } }
                    if phase == .background { Self.scheduleRefresh() }
                }
        }
        // iOS decides when (by how the app is used, typically a few times a day) and allows about 30 seconds:
        // queued changes go out and the saved copy is brought up to date.
        .backgroundTask(.appRefresh(Self.refreshTask)) {
            await Self.scheduleRefresh()   // each request runs once, so ask for the next one first
            await store.refresh()
        }
    }

    private static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = .now.addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Calendar", systemImage: "calendar", value: 0) {
                NavigationStack { CalendarScreen().appToolbar() }
            }
            Tab("Tasks", systemImage: "checklist", value: 1) {
                TasksScreen()
            }
            Tab("Notes", systemImage: "note.text", value: 2) {
                NotesScreen()
            }
            Tab("Settings", systemImage: "gearshape", value: 3) {
                SettingsView()
            }
        }
        .onChange(of: store.openNote, initial: true) {
            if store.openNote != nil { tab = 2 }   // NotesScreen then opens it
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = store.errorMessage { errorBar(message) }
        }
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.important).accessibilityHidden(true)
            Text(message).font(.footnote).lineLimit(3)
            Spacer(minLength: 0)
            Button { store.errorMessage = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("Dismiss error")
        }
        .padding(.leading, 14)
        .background(.bar)
    }
}

extension View {
    /// The controls every main screen has: sync state and the private toggle. Account and settings are their own tab.
    func appToolbar() -> some View { modifier(AppToolbar()) }
}

private struct AppToolbar: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if store.isOffline || !store.pending.isEmpty {
                    Image(systemName: store.isOffline ? "wifi.slash" : "arrow.up.circle")
                        .foregroundStyle(Color.subtle)
                        .accessibilityLabel(store.isOffline ? "Offline, \(store.pending.count) changes to send" : "Sending changes")
                } else if store.isSyncing {
                    ProgressView()
                }
                Button { store.showPrivate.toggle() } label: {
                    Label(store.showPrivate ? "Hide Private" : "Show Private", systemImage: store.showPrivate ? "eye" : "eye.slash")
                }
            }
        }
    }
}
