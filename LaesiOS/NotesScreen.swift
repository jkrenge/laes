import SwiftUI

/// All notes with search. On iPhone tapping one pushes it; on iPad it opens beside the list.
struct NotesScreen: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var selected: String?   // the open note's file name
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Group {
                if !store.notesReady {
                    NotesIntro()
                } else {
                    List(selection: $selected) {
                        if let error = store.notesError {
                            Text(error).font(.footnote).foregroundStyle(Color.overdue)
                        }
                        ForEach(store.noteRows(matching: query)) { hit in
                            NoteRow(hit: hit).tag(hit.note.name)
                        }
                        Button("New Note", systemImage: "plus") { selected = store.addNote().name }
                    }
                    .searchable(text: $query, prompt: "Search notes")
                    .refreshable { await store.refresh() }
                }
            }
            .navigationTitle("Notes")
            .toolbar(removing: .sidebarToggle)   // iPad: the list always stays
            .modifier(AppToolbarIf(sizeClass != .regular))
        } detail: {
            if let note = store.visibleNotes.first(where: { $0.name == selected }) {
                NoteEditor(note: note).id(note.name).navigationBarTitleDisplayMode(.inline)   // brings the app's buttons on iPad
            } else {
                Text(selected == nil ? "Select a note" : "This note is hidden or was deleted").foregroundStyle(Color.subtle)
                    .modifier(AppToolbarIf(sizeClass == .regular))   // iPad: the eye at the top right, as in Calendar and Tasks
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: store.openNote, initial: true) {
            guard let name = store.openNote else { return }
            (selected, store.openNote) = (name, nil)
        }
    }
}

/// The app toolbar only where asked: over the list on iPhone, over the open note on iPad.
private struct AppToolbarIf: ViewModifier {
    let shown: Bool
    init(_ shown: Bool) { self.shown = shown }
    func body(content: Content) -> some View {
        if shown { content.appToolbar() } else { content }
    }
}
