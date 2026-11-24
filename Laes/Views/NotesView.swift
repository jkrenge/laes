import SwiftUI

extension AppStore {
    /// Notes work on sample data, and on an account once the user has allowed the OneDrive folder.
    var notesReady: Bool { !isSignedIn || notesEnabled }

    /// Newest first, or the best matches for a search.
    func noteRows(matching query: String) -> [NoteHit] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return searchNotes(visibleNotes, query, limit: 50) }
        return visibleNotes.filter { !$0.isBlank }.sorted { $0.modified > $1.modified }.map { note in
            let line = note.body.components(separatedBy: "\n").first { !$0.isEmpty && !$0.hasPrefix("# ") } ?? ""
            return NoteHit(note: note, score: 0, snippet: String(line.drop { "#-*+ ".contains($0) }.prefix(200)))
        }
    }
}

/// Explains where notes are kept and asks Microsoft for the folder.
struct NotesIntro: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text").font(.largeTitle).foregroundStyle(Color.subtle).accessibilityHidden(true)
            Text("Notes").font(.title2.weight(.semibold))
            Text("Notes are switched off. They are Markdown files in your OneDrive, in a folder only lães uses. You can link them to meetings, and lães reminds you of them five minutes before. Microsoft asks you to allow the folder once.")
                .foregroundStyle(Color.subtle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Turn On Notes") { Task { await store.enableNotes() } }
                .buttonStyle(.borderedProminent)
                .tint(Color.brand)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoteRow: View {
    let hit: NoteHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.note.title).lineLimit(1)
            if let event = hit.note.meta("event_title") {
                HStack(spacing: 3) { Image(systemName: "calendar"); Text(event) }
                    .font(.caption).foregroundStyle(Color.brandText).lineLimit(1)
            }
            if !hit.snippet.isEmpty {
                Text(hit.snippet).font(.caption).foregroundStyle(Color.subtle).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One note: formatted Markdown, or its source while editing. The title is the note's first "# " line.
/// Saves when editing ends or the note is left.
struct NoteEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss   // back to the list after a delete on iPhone; nothing on Mac
    let note: Note
    @State private var draft = ""
    @State private var selection: TextSelection?
    @State private var isEditing = false
    @State private var confirmDelete = false
    @State private var copied = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if let event = note.meta("event_title") {
                    Label([event, note.eventStart?.formatted(date: .abbreviated, time: .shortened)].compactMap(\.self).joined(separator: " · "),
                          systemImage: "calendar")
                        .font(.callout)
                        .foregroundStyle(Color.brandText)
                        .lineLimit(1)
                }
                #if os(macOS)
                Spacer(minLength: 0)
                controls
                #endif
            }
            #if os(macOS)
            Divider()
            #endif
            if isEditing {
                TextEditor(text: $draft, selection: $selection)
                    .focused($isFocused)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Note in Markdown")
            } else {
                ScrollView {
                    Text(renderMarkdown(draft))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                #if os(iOS)
                .contentMargins(.bottom, 80, for: .scrollContent)   // room to scroll the end above the edit button
                #endif
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(iOS)
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if copied {
                    Text("Copied").font(.subheadline.weight(.medium))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .glassCapsule()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if !isEditing {
                    Button(action: edit) {
                        Label("Edit this note", systemImage: "pencil")
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 22)
                            .frame(height: 48)
                    }
                    .glassCapsule()
                }
            }
            .padding(.bottom, 12)
            .animation(.snappy, value: copied)
        }
        .onChange(of: isFocused) { _, focused in
            if !focused, isEditing, menu == nil { finish() }   // keyboard hidden: back to the formatted note
        }
        .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { controls } }
        .toolbar(.hidden, for: .tabBar)   // room for the note, and nothing under the formatting bar
        .safeAreaInset(edge: .bottom) {
            if isEditing, isFocused || menu != nil { formatBar }   // only while the keyboard is up
        }
        #endif
        .onAppear {
            draft = note.body
            if note.isBlank { edit() }   // a new note: type the title right away
        }
        .onDisappear { save() }
        .onChange(of: note.text) {
            if !isEditing { draft = note.body }   // changed elsewhere, for example by an AI tool
        }
        .alert("Delete “\(note.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                dismiss()
                Task { await store.deleteNote(note) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file is removed from your OneDrive folder.")
        }
    }

    /// Switch between the Markdown source and the formatted note, copy it, delete it.
    @ViewBuilder private var controls: some View {
        if note.isDirty, !note.isBlank {
            Image(systemName: "arrow.up.circle").foregroundStyle(Color.subtle)
                .help("Not yet saved to OneDrive").accessibilityLabel("Not yet saved to OneDrive")
        }
        #if os(macOS)   // on iPhone: the floating edit button, and hiding the keyboard finishes
        Button(isEditing ? "Show Formatted" : "Edit Markdown", systemImage: isEditing ? "eye" : "pencil") {
            if isEditing { finish() } else { edit() }
        }
        .help(isEditing ? "Show the note formatted" : "Edit the Markdown")
        #endif
        Button(copied ? "Copied" : "Copy Note", systemImage: copied ? "checkmark" : "doc.on.doc") {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(draft, forType: .string)
            #else
            UIPasteboard.general.string = draft
            #endif
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .help("Copy the whole note as Markdown")
        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            .tint(Color.overdue)
    }

    private func edit() {
        isEditing = true
        DispatchQueue.main.async {   // the editor exists one runloop turn later
            isFocused = true
            selection = TextSelection(insertionPoint: draft.endIndex)
        }
    }

    private func finish() {
        isEditing = false
        let name = save()
        if name != note.name { store.openNote = name }   // it took its file name from the title: follow it
    }

    @discardableResult
    private func save() -> String {
        var edited = note
        edited.update(body: draft)
        return store.saveNote(edited)
    }

    #if os(iOS)
    private enum BarMenu { case style, list }
    @State private var menu: BarMenu?

    /// Floats just above the keyboard. Style and list open a small pop-up over the bar; bar and keyboard stay.
    private var formatBar: some View {
        HStack(spacing: 0) {
            barButton("Hide Keyboard", "keyboard.chevron.compact.down") { isFocused = false }
            Divider().frame(height: 22).padding(.horizontal, 4)
            barButton("Heading", "number") { apply(.insert("#")) }
            barMenu("Text Style", "textformat", .style, [
                ("Bold", "bold", .wrap("**", "**")), ("Italic", "italic", .wrap("*", "*")),
                ("Underline", "underline", .wrap("<u>", "</u>")), ("Strikethrough", "strikethrough", .wrap("~~", "~~")),
                ("Code", "chevron.left.forwardslash.chevron.right", .wrap("`", "`")),
            ])
            barMenu("List", "list.bullet", .list, [
                ("Bulleted List", "list.bullet", .list("- ")), ("Numbered List", "list.number", .list("1. ")),
                ("To-Do List", "checklist", .list("- [ ] ")),
            ])
            barButton("Outdent", "decrease.indent") { apply(.dedent) }
            barButton("Indent", "increase.indent") { apply(.indent) }
            barButton("Link", "link") {
                Task { apply(.link(url: await Self.copiedURL())) }
            }
        }
        .padding(.horizontal, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func barButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(maxWidth: .infinity, minHeight: 46).contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }

    private func barMenu(_ title: String, _ icon: String, _ id: BarMenu, _ items: [(title: String, icon: String, action: MarkdownAction)]) -> some View {
        barButton(title, icon) { menu = id }
            .popover(isPresented: Binding(get: { menu == id }, set: { if !$0 { menu = nil } }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.title) { item in
                        Button {
                            menu = nil
                            apply(item.action)
                        } label: {
                            Label(item.title, systemImage: item.icon).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .presentationCompactAdaptation(.popover)
            }
    }

    /// A web address on the clipboard, for the link button. The pattern check itself doesn't make iOS ask about pasting.
    private static func copiedURL() async -> String? {
        guard (try? await UIPasteboard.general.detectedPatterns(for: [\.probableWebURL]))?.isEmpty == false else { return nil }
        return UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func apply(_ action: MarkdownAction) {
        var range = draft.count..<draft.count
        if case .selection(let chosen) = selection?.indices, chosen.upperBound <= draft.endIndex {
            range = draft.distance(from: draft.startIndex, to: chosen.lowerBound)..<draft.distance(from: draft.startIndex, to: chosen.upperBound)
        }
        let result = action.apply(to: draft, selection: range)
        draft = result.text
        selection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: result.selection.lowerBound))
        isFocused = true
    }
    #endif
}

#if os(macOS)
/// Notes on the left with search, the chosen one on the right.
struct NotesView: View {
    @Environment(AppStore.self) private var store
    var isShown = true   // hidden behind another view, its fields take no focus
    @State private var query = ""
    @State private var selected: String?

    var body: some View {
        if !store.notesReady {
            NotesIntro()
        } else {
            HStack(spacing: 0) {
                // Search and New Note sit in the list's insets, so the sidebar background runs behind them as in Tasks.
                List(store.noteRows(matching: query), selection: $selected) { NoteRow(hit: $0).tag($0.note.name) }
                    .listStyle(.sidebar)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            TextField("Search notes", text: $query)
                                .textFieldStyle(.roundedBorder)
                                .disabled(!isShown)
                                .padding(10)
                            if let error = store.notesError {
                                Text(error).font(.caption).foregroundStyle(Color.overdue).padding(.horizontal, 12).padding(.bottom, 6)
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
                        Button("New Note", systemImage: "plus") { selected = store.addNote().name }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.subtle)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .frame(width: 280)
                Divider()
                if let note = store.visibleNotes.first(where: { $0.name == selected }) {
                    NoteEditor(note: note).id(note.name).disabled(!isShown)
                } else {
                    Text(store.visibleNotes.isEmpty ? "No notes yet" : "Select a note")
                        .foregroundStyle(Color.subtle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: store.openNote, initial: true) {
                guard let name = store.openNote else { return }
                (selected, store.openNote) = (name, nil)
            }
        }
    }
}
#endif
