import SwiftUI

/// All notes with search; tapping one pushes it.
struct NotesScreen: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var path: [String] = []   // the open note's file name

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !store.notesReady {
                    NotesIntro()
                } else {
                    List {
                        if let error = store.notesError {
                            Text(error).font(.footnote).foregroundStyle(Color.overdue)
                        }
                        ForEach(store.noteRows(matching: query)) { hit in
                            NavigationLink(value: hit.note.name) { NoteRow(hit: hit) }
                        }
                        Button("New Note", systemImage: "plus") { path = [store.addNote().name] }
                    }
                    .searchable(text: $query, prompt: "Search notes")
                    .refreshable { await store.refresh() }
                }
            }
            .navigationTitle("Notes")
            .navigationDestination(for: String.self) { name in
                if let note = store.visibleNotes.first(where: { $0.name == name }) {
                    NoteEditor(note: note).navigationBarTitleDisplayMode(.inline)
                } else {
                    Text("This note is hidden or was deleted").foregroundStyle(Color.subtle)
                }
            }
            .appToolbar()
        }
        .onChange(of: store.openNote, initial: true) {
            guard let name = store.openNote else { return }
            (path, store.openNote) = ([name], nil)
        }
    }
}
