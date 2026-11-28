#if os(macOS)
import SwiftUI

/// The search across everything: what is typed in the toolbar's field, and the result the arrow keys are on.
@MainActor @Observable final class SearchModel {
    var query = "" {
        didSet {
            (pickedID, isShown) = (nil, true)
            if hasText == query.isEmpty { hasText = !query.isEmpty }   // set only when it changes: the toolbar reads it
        }
    }
    private(set) var hasText = false
    var pickedID: String?   // by id, so results that arrive while typing don't move the highlight
    var isShown = false   // the results, while there is something typed
    var isActive: Bool { isShown && !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Searched once per query and state of the data: the panel, the arrow keys and Return all read the same results.
    @ObservationIgnored private var cache: (key: [AnyHashable], results: SearchResults)?
    func results(in store: AppStore, first: SearchResults.Kind, now: Date = .now) -> SearchResults {
        let key: [AnyHashable] = [query, first, store.showPrivate, store.visibleTasks.count, store.visibleCompleted.count,
                                  store.visibleNotes.count, store.events.count, store.farEvents.count]
        if let cache, cache.key == key { return cache.results }
        let results = store.search(query, first: first, now: now)
        cache = (key, results)
        return results
    }
}

/// What the search found, by kind.
struct SearchResults {
    enum Kind: String, CaseIterable {
        case tasks = "Tasks", notes = "Notes", meetings = "Meetings"
        /// The kind of the view in front comes first, with more room.
        static func ordered(first: Kind) -> [Kind] { [first] + allCases.filter { $0 != first } }
    }
    enum Target { case task(String), note(String), event(CalendarEvent) }
    struct Hit: Identifiable {
        let id: String
        let target: Target
        let title: String
        let detail: String
        let icon: String
        var isDone = false
    }
    var sections: [(kind: Kind, hits: [Hit], total: Int)]
    var hits: [Hit] { sections.flatMap(\.hits) }
}

extension AppStore {
    /// Tasks (open, then done), notes and meetings matching `query`, typos forgiven. `first`'s kind leads with eight,
    /// the others show four; done tasks get half as many again, so open ones never crowd them out.
    func search(_ query: String, first: SearchResults.Kind, now: Date = .now) -> SearchResults {
        let day = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        func hits(_ kind: SearchResults.Kind) -> (shown: [SearchResults.Hit], total: Int) {
            let room = kind == first ? 8 : 4
            switch kind {
            case .tasks:
                let open: [SearchResults.Hit] = searchTasks(visibleTasks, query).map { task in
                    .init(id: "task:" + task.id, target: .task(task.id), title: task.title,
                          detail: ([task.listName] + (task.due.map { ["Due " + $0.formatted(day)] } ?? [])).joined(separator: " · "), icon: "circle")
                }
                let done: [SearchResults.Hit] = searchTasks(visibleCompleted, query).map { task in
                    .init(id: "task:" + task.id, target: .task(task.id), title: task.title,
                          detail: ([task.listName] + (task.completed.map { ["Completed " + $0.formatted(day)] } ?? [])).joined(separator: " · "),
                          icon: "checkmark.circle.fill", isDone: true)
                }
                return (Array(open.prefix(room)) + done.prefix(room / 2), open.count + done.count)
            case .notes:
                let notes = searchNotes(visibleNotes.filter { !$0.isSettings }, query, limit: 50)
                return (notes.prefix(room).map {
                    .init(id: "note:" + $0.note.name, target: .note($0.note.name), title: $0.note.title, detail: $0.snippet, icon: "note.text")
                }, notes.count)
            case .meetings:
                let events = searchEvents(visibleSearchEvents, query, now: now)
                return (events.prefix(room).map { event in
                    let when = event.isAllDay ? event.start.formatted(day) : event.start.formatted(day.hour().minute())
                    return .init(id: "event:" + event.id, target: .event(event), title: event.title,
                                 detail: ([when] + (event.location.map { [$0] } ?? [])).joined(separator: " · "), icon: "calendar")
                }, events.count)
            }
        }
        return SearchResults(sections: SearchResults.Kind.ordered(first: first).compactMap { kind in
            let found = hits(kind)
            return found.shown.isEmpty ? nil : (kind, found.shown, found.total)
        })
    }
}

/// The field in the middle of the toolbar. ↓ and ↑ move through the results, Return opens one, Esc clears.
struct SearchField: View {
    @Environment(AppStore.self) private var store
    @Bindable var model: SearchModel
    let first: SearchResults.Kind
    let open: (SearchResults.Hit) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.subtle).accessibilityHidden(true)
            TextField("Search", text: $model.query, prompt: Text(""))
                .textFieldStyle(.plain)
                .overlay(alignment: .leading) {   // our own: the toolbar draws a field's prompt as bright as its text
                    if model.query.isEmpty { Text("Search for anything").foregroundStyle(Color.subtle).allowsHitTesting(false).accessibilityHidden(true) }
                }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onSubmit {
                    let hits = model.results(in: store, first: first).hits
                    if model.isActive, let hit = hits.first(where: { $0.id == model.pickedID }) ?? hits.first { open(hit) }
                }
                .onExitCommand {
                    (model.query, model.isShown) = ("", false)
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                .accessibilityLabel("Search tasks, notes and meetings")
            if model.query.isEmpty {
                Keycap("⌘F")
            } else {
                Button { model.query = ""; model.isShown = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.subtle)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 300, height: 28)
        .simultaneousGesture(TapGesture().onEnded { if !model.query.isEmpty { model.isShown = true } })   // back in the field: its results again
    }

    /// Puts the cursor in the field (⌘F). Through AppKit: SwiftUI's focus doesn't reach a field in the toolbar.
    static func focus() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }),
              let frame = window.contentView?.superview else { return }
        let content = window.contentLayoutRect   // the field is the one above it, in the toolbar
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, field.convert(field.bounds, to: nil).minY >= content.maxY { return field }
            return view.subviews.lazy.compactMap(field).first
        }
        if let found = field(in: frame) { window.makeFirstResponder(found) }
    }

    private func move(_ by: Int) -> KeyPress.Result {
        guard model.isActive else { return .ignored }
        let hits = model.results(in: store, first: first).hits
        guard !hits.isEmpty else { return .handled }
        let index = hits.firstIndex { $0.id == model.pickedID } ?? 0
        model.pickedID = hits[min(max(index + by, 0), hits.count - 1)].id
        return .handled
    }
}

/// A shortcut drawn as a key.
struct Keycap: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.subtle)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.3)))
            .accessibilityHidden(true)
    }
}

/// The results, dropped from under the field over whatever view is in front.
struct SearchPanel: View {
    @Environment(AppStore.self) private var store
    let model: SearchModel
    let first: SearchResults.Kind
    let now: Date
    let open: (SearchResults.Hit) -> Void

    var body: some View {
        if model.isActive {
            let results = model.results(in: store, first: first, now: now)
            let picked = results.hits.first { $0.id == model.pickedID }?.id ?? results.hits.first?.id
            ZStack(alignment: .top) {
                Color.black.opacity(0.001).onTapGesture { model.isShown = false }   // a click elsewhere puts the results away
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(results.sections, id: \.kind) { section in
                                Text(section.total > section.hits.count ? "\(section.kind.rawValue) · \(section.hits.count) of \(section.total)" : section.kind.rawValue)
                                    .font(.caption.weight(.semibold)).foregroundStyle(Color.subtle)
                                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(section.hits) { hit in row(hit, isPicked: hit.id == picked) }
                            }
                            if results.sections.isEmpty {
                                Text(store.isLoadingCompleted ? "Searching…" : "Nothing found")
                                    .foregroundStyle(Color.subtle).frame(maxWidth: .infinity).padding(24)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: picked) { if let picked { proxy.scrollTo(picked) } }
                }
                .frame(width: 520)
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
                .card()
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                .padding(.top, 2)
            }
            .task {   // done tasks and meetings beyond these weeks, side by side
                async let done: Void = store.loadCompleted(), meetings: Void = store.loadSearchEvents()
                _ = await (done, meetings)
            }
        }
    }

    private func row(_ hit: SearchResults.Hit, isPicked: Bool) -> some View {
        Button { open(hit) } label: {
            HStack(spacing: 10) {
                Image(systemName: hit.icon).foregroundStyle(Color.subtle).frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(highlighting(hit.title, model.query)).strikethrough(hit.isDone).foregroundStyle(hit.isDone ? Color.subtle : Color.primary).lineLimit(1)
                    if !hit.detail.isEmpty { Text(hit.detail).font(.caption).foregroundStyle(Color.subtle).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isPicked ? Color.brand.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(hit.id)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}
#endif
