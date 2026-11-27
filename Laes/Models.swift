import Foundation

// Shared contract between the Graph layer and the views. Change only with care.

enum ShowAs: String, Codable, Sendable {
    case free, tentative, busy, oof, workingElsewhere, unknown
}

enum ResponseStatus: String, Codable, Sendable {
    case none, organizer, tentativelyAccepted, accepted, declined, notResponded
}

struct CalendarEvent: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var location: String?
    var categories: [String] = []
    var showAs: ShowAs = .busy
    var response: ResponseStatus = .none
    var isPrivate = false
    var isRecurring = false
    var isOnlineMeeting = false
    var isCancelled = false
    var webLink: URL?
    var attendees: [String] = []
    var joinURL: URL?
    var isRedacted = false   // a private meeting's stand-in while the private group is hidden; never saved

    private enum CodingKeys: String, CodingKey {
        case id, title, start, end, isAllDay, location, categories, showAs, response, isPrivate, isRecurring,
             isOnlineMeeting, isCancelled, webLink, attendees, joinURL
    }

    /// Created here (carries the lães category): the only meetings that can be resized or deleted here.
    var isOwn: Bool { categories.contains(ownCategory) }

    /// Every word of `query` is in the title, place or attendees, ignoring case and accents. An empty query matches all.
    func matches(_ query: String) -> Bool {
        let haystack = ([title, location ?? ""] + attendees).joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { haystack.localizedStandardContains($0) }
    }

    /// Only the time it takes, whether it is free and whether it still stands: the calendar shows a private meeting
    /// like this while the private group is hidden, so the time reads as taken without saying what for.
    var redacted: CalendarEvent {
        CalendarEvent(id: id, title: "", start: start, end: end, isAllDay: isAllDay, showAs: showAs, response: response,
                      isCancelled: isCancelled, isRedacted: true)
    }
}

/// Outlook category put on meetings created in lães.
let ownCategory = "lães"

struct TodoTask: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var listName: String
    var listID = ""
    var due: Date?          // start of the due day, local time zone
    var isImportant = false
    var webLink: URL?
    var notes = ""              // plain text
    var notesReadOnly = false   // formatted (HTML) in Outlook: shown as text, never overwritten
    var repeats: RepeatRule?    // nil for one-off tasks
    var reminder: Date?         // when To Do reminds the user; nil if off
    var completed: Date?        // when it was ticked off; nil while open

    var recurrence: String? { repeats?.text }
}

/// A task's repeat rule, in the shapes To Do's own picker offers. The day it falls on follows the due date.
struct RepeatRule: Codable, Hashable, Sendable {
    enum Unit: String, Codable, CaseIterable, Sendable {
        case daily, weekdays, weekly, monthly, yearly
        var title: String { rawValue.capitalized }
    }
    var unit: Unit
    var interval = 1

    private var names: (one: String, many: String) {
        switch unit {
        case .daily: ("day", "days")
        case .weekdays: ("weekday", "weekdays")
        case .weekly: ("week", "weeks")
        case .monthly: ("month", "months")
        case .yearly: ("year", "years")
        }
    }
    /// "Every 2 weeks", for the interval stepper.
    var every: String { interval > 1 ? "Every \(interval) \(names.many)" : "Every \(names.one)" }
    var text: String {
        if unit == .weekdays { return "Repeats on weekdays" }
        return interval > 1 ? "Repeats every \(interval) \(names.many)" : "Repeats \(unit.rawValue)"
    }
}

/// A subtask ("step" in To Do).
struct ChecklistItem: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var isChecked = false
}

struct TaskList: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var isDefault = false   // To Do's built-in "Tasks" list; new tasks go here
    var isFlagged = false   // To Do's built-in "Flagged Emails" list

    /// Microsoft's two built-in lists, which can't be renamed or deleted.
    var isBuiltIn: Bool { isDefault || isFlagged }
    var icon: String { isFlagged ? "flag" : "tray" }

    // Decoded by hand so a copy saved before `isFlagged` existed still loads.
    init(id: String, name: String, isDefault: Bool = false, isFlagged: Bool = false) {
        (self.id, self.name, self.isDefault, self.isFlagged) = (id, name, isDefault, isFlagged)
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        isDefault = try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        isFlagged = try values.decodeIfPresent(Bool.self, forKey: .isFlagged) ?? false
    }
}

/// Case-insensitive: does any of an event's categories belong to the private set?
func hasCategory(_ categories: [String], in set: Set<String>) -> Bool {
    categories.contains { c in set.contains { $0.caseInsensitiveCompare(c) == .orderedSame } }
}

extension Calendar {
    /// Gregorian calendar in the current time zone whose weeks start on the chosen day (Saturday by default).
    static var laes: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = UserDefaults.standard.object(forKey: "firstWeekday") as? Int ?? 7
        return cal
    }

    func weekStart(for date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)!.start
    }
}
