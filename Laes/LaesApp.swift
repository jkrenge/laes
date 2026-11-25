import SwiftUI

@main
struct LaesApp: App {
    @State private var store = AppStore()

    #if DEBUG
    init() {
        // Launched in the background, macOS sometimes restores the app with no window; open one for the shot.
        guard ProcessInfo.processInfo.arguments.contains("-shot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !NSApp.windows.contains(where: \.isVisible) else { return }
            let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
            if let new = items.first(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }) {
                new.menu?.performActionForItem(at: new.menu!.index(of: new))
            }
        }
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task { IconDesign.saved?.showInDock() }   // macOS forgets a changed Dock icon when the app quits
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await store.refreshIfStale() }
                }
                #if DEBUG
                .task { await Self.shootIfAsked(store) }
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("-mcpCheck") else { return }
                    try? await Task.sleep(for: .seconds(6))   // signed in, cache loaded, server listening
                    await MCPServer.check(store)
                }
                #endif
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-benchViews") { return }   // measure switching, not syncing
                    #endif
                    // Background sync every 5 minutes while the window is open.
                    while !Task.isCancelled {
                        await store.refresh()
                        try? await Task.sleep(for: .seconds(300))
                    }
                }
        }
        .defaultSize(width: 1440, height: 960)

        .commands {
            HelpCommands()
            CommandMenu("Task") { TaskMenu().environment(store) }
        }

        Window("lães Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 520, height: 640)

        Settings {
            SettingsView().environment(store)
        }
    }

    #if DEBUG
    /// `-demo -shot <file.png> [-openFirstNote]`: saves the window as an image and quits. For the website's screenshots.
    private static func shootIfAsked(_ store: AppStore) async {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-shot"), index + 1 < args.count else { return }
        if args.contains("-openFirstNote") { store.openNote = store.notes.first?.name }
        // Outside any SwiftUI update: drawing the window from inside one never returns.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            defer { NSApp.terminate(nil) }
            guard let window = NSApp.windows.filter(\.isVisible).max(by: { $0.frame.width < $1.frame.width }),
                  let frame = window.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[index + 1]))
        }
    }
    #endif
}

/// The Task menu acts on the task selected in the task list.
private struct TaskMenu: View {
    @FocusedValue(\.selectedTask) private var task
    var body: some View { TaskActions(task: task) }
}
