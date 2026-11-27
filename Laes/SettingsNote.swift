import Foundation

/// The note that carries the settings every device on the account shares. Laes writes it; it is read-only in the app.
let settingsNoteName = "lães settings.md"

extension Note {
    var isSettings: Bool { name == settingsNoteName }
}

/// The settings kept in the settings note: in its header for Laes, and in its body in words for people.
/// Other settings stay on each device.
struct SharedSettings: Equatable {
    var showPrivate: Bool
    var privateCategories: Set<String>
    var privateListIDs: Set<String>
    var listOrder: [String]
    var firstWeekday: Int
    var firstHour: Int
    var lastHour: Int

    // shortcut: values are joined with ", ", so a category name with a comma in it splits in two; quote values if that matters.
    private static func list(_ value: String?) -> [String] {
        value?.components(separatedBy: ", ").filter { !$0.isEmpty } ?? []
    }

    /// Nil when the note isn't a settings note Laes can read.
    init?(_ note: Note) {
        guard note.meta("laes") == "settings",
              let showPrivate = note.meta("show_private").flatMap(Bool.init),
              let firstWeekday = note.meta("first_weekday").flatMap(Int.init), (1...7).contains(firstWeekday),
              let firstHour = note.meta("first_hour").flatMap(Int.init),
              let lastHour = note.meta("last_hour").flatMap(Int.init), 0 <= firstHour, firstHour < lastHour, lastHour <= 24 else { return nil }
        self.init(showPrivate: showPrivate, privateCategories: Set(Self.list(note.meta("private_categories"))),
                  privateListIDs: Set(Self.list(note.meta("private_lists"))), listOrder: Self.list(note.meta("list_order")),
                  firstWeekday: firstWeekday, firstHour: firstHour, lastHour: lastHour)
    }

    init(showPrivate: Bool, privateCategories: Set<String>, privateListIDs: Set<String>, listOrder: [String],
         firstWeekday: Int, firstHour: Int, lastHour: Int) {
        (self.showPrivate, self.privateCategories, self.privateListIDs, self.listOrder) = (showPrivate, privateCategories, privateListIDs, listOrder)
        (self.firstWeekday, self.firstHour, self.lastHour) = (firstWeekday, firstHour, lastHour)
    }

    /// The whole file. `listNames` turns list ids into names for the part people read.
    func text(listNames: [String: String]) -> String {
        let meta: NoteMeta = [
            ("laes", "settings"),
            ("show_private", String(showPrivate)),
            ("private_categories", privateCategories.sorted().joined(separator: ", ")),
            ("private_lists", privateListIDs.sorted().joined(separator: ", ")),
            ("list_order", listOrder.joined(separator: ", ")),
            ("first_weekday", String(firstWeekday)),
            ("first_hour", String(firstHour)),
            ("last_hour", String(lastHour)),
        ]
        func names(_ ids: [String]) -> String { ids.compactMap { listNames[$0] }.joined(separator: ", ").nonEmpty ?? "none" }
        let body = """
            # lães settings

            lães keeps these settings here, so every device signed in to this account uses the same ones. \
            Change them in lães's settings: this note is read-only, and edits made to the file elsewhere are overwritten.

            - Private meetings are \(showPrivate ? "shown" : "hidden")
            - Private calendar categories: \(privateCategories.sorted().joined(separator: ", ").nonEmpty ?? "none")
            - Private lists: \(names(privateListIDs.sorted()))
            - List order: \(names(listOrder))
            - Weeks start on \(Calendar.current.weekdaySymbols[firstWeekday - 1])
            - Hours shown: \(firstHour):00 to \(lastHour):00
            """
        return joinFrontMatter(meta, body)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
