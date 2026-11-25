import SwiftUI

/// Shown once on first launch, and again from Help > Welcome to lães. Short and skippable: the sample
/// data behind it is the real tour.
struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            Text("Welcome to lães")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 10)
            Text("Your work calendar, Microsoft To Do and meeting notes, two weeks at a time.")
                .font(.body)
                .foregroundStyle(Color.subtle)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 18) {
                point("calendar", "Two weeks, one screen",
                      "This week on top, next week below, Saturday to Friday. No scrolling.")
                point("checklist", "Tasks sit on their day",
                      "Click a task to open it, drag it to another day to reschedule, click empty space to add one.")
                point("note.text", "Notes for your meetings",
                      "Write notes in Markdown, link them to a meeting, and get them back five minutes before it starts. They are files in your own OneDrive.")
                point("sparkles", "Works with your AI tools",
                      "Switch on AI Access in Settings and an assistant on this Mac can plan your tasks and prepare your notes.")
                point("eye.slash", "Private when you need it",
                      "Mark categories and task lists as private, then hide them all with one button.")
                point("lock.shield", "Between you and Microsoft",
                      "lães talks only to your Microsoft account. A copy is kept on this Mac so it works offline.")
            }
            .padding(.top, 28)
            .padding(.bottom, 30)

            if store.isSignedIn {
                Button("Continue") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Sign In with Microsoft") {
                    dismiss()
                    Task { await store.signIn() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button("Look Around with Sample Data") { dismiss() }
                    .buttonStyle(.link)
                    .padding(.top, 10)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .tint(.brand)
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 480)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Color.brand)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Help > lães Help. Tips grouped by what you are trying to do.
struct HelpView: View {
    private static let topics: [(symbol: String, title: String, lines: [String])] = [
        ("calendar", "Getting around", [
            "The window shows two weeks, starting on the day set in Settings (Saturday unless you change it): the top row is the first week, the bottom row the week after.",
            "Today (⌘T) jumps back to the current week. The arrows (⌘← and ⌘→) move one week at a time.",
            "Click a meeting to see its time, place, category and status. Meetings from Outlook can't be changed here; time you blocked in lães can be lengthened from its bottom edge or deleted.",
            "An all-day event tints its whole day column, unless it is marked free, cancelled or declined.",
        ]),
        ("checklist", "Tasks", [
            "Each day lists the tasks due that day, under the day's header. Overdue tasks collect on today, with their original date in red.",
            "Click a task to open it. That is where you tick it off, tick or rename subtasks, add a subtask, and write a note.",
            "Drag a task onto another day to change its due date, or into a day's hours to block time for it.",
            "Click empty space under a day to add a task for that day. On a full day, scroll to “Add task” at the end of the list. New tasks go to your default To Do list.",
            "Completing a repeating task brings up its next occurrence a few seconds later.",
        ]),
        ("note.text", "Notes", [
            "Notes are Markdown files in a OneDrive folder only lães uses. The first line, starting with #, is the title.",
            "New Note starts an empty note with the cursor in the title. Double-click a note to edit it where you clicked; Esc or Done stops. Formatting shows as you type, with its Markdown dimmed.",
            "Return continues a list. ⌘B, ⌘I, ⌘U and ⌘S style the selection; ⌘L, ⌘O and ⌘T make a list, a numbered list or a to-do list; ⌘K adds a link, and Tab moves from its label to its address. Select text or hold ⌘ to see them all.",
            "To write a note for a meeting, click the meeting and choose Add Note. Five minutes before it starts, lães reminds you of its notes.",
            "Search looks through the full text of every note. Notes written by an AI tool or on another device appear after the next refresh.",
        ]),
        ("eye.slash", "Private items", [
            "In Settings (⌘,), switch on the calendar categories and task lists that are private.",
            "The eye button in the toolbar (⇧⌘P) hides or shows all of them at once, for example before sharing your screen. Hidden meetings stay as plain blocks of time, without their title; hidden tasks and notes disappear.",
        ]),
        ("arrow.clockwise", "Syncing and working offline", [
            "lães refreshes every five minutes and when you press Refresh (⌘R). Hover over Refresh to see when it last synced.",
            "Without a connection you see the last synced data, and the toolbar says Offline.",
            "Task changes made offline are saved on this Mac and sent, in order, when the connection returns.",
        ]),
        ("person.crop.circle", "Signing in", [
            "Sign in with the Microsoft work, school or personal account that holds your calendar. You can pick or add an account each time.",
            "If Microsoft says “Need admin approval”, your organisation requires its IT team to approve lães once. Send them the message shown on that screen.",
            "Sign Out, in the account menu, also deletes the copy of your data kept on this Mac.",
        ]),
        ("lock.shield", "Your data", [
            "lães connects only to Microsoft, to sign you in and to read and update your own calendar and tasks. Nothing is sent anywhere else.",
            "The sign-in is stored in your Mac's Keychain. The offline copy is stored in your user Library.",
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(Self.topics, id: \.title) { topic in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(topic.title, systemImage: topic.symbol)
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        ForEach(topic.lines, id: \.self) { line in
                            Text(line)
                                .foregroundStyle(Color.primary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 640)
    }
}

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showWelcome") private var showWelcome = true

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("lães Help") { openWindow(id: "help") }
                .keyboardShortcut("?")
            Button("Welcome to lães…") { showWelcome = true }
        }
    }
}
