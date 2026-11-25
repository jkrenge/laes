import Foundation
import UserNotifications

/// A notification five minutes before each meeting that has notes. Tapping it opens the first note.
final class NoteReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoteReminders()
    static let lead: TimeInterval = 5 * 60
    var open: ((String) -> Void)?

    func start(open: @escaping (String) -> Void) {
        self.open = open
        UNUserNotificationCenter.current().delegate = self
    }

    /// The meetings that have notes, taken from the notes themselves: each knows its meeting's id, title and start, so
    /// meetings outside the weeks on screen get their reminder too (one an AI tool wrote notes for, say). A loaded
    /// meeting's current time and title win, in case it moved; one that was cancelled or declined gets none.
    static func meetings(for notes: [Note], loaded events: [CalendarEvent]) -> [(event: CalendarEvent, notes: [Note])] {
        Dictionary(grouping: notes.filter { $0.eventID != nil }, by: { $0.eventID! }).compactMap { id, notes in
            if let event = events.first(where: { $0.id == id }) {
                return event.isCancelled || event.response == .declined ? nil : (event, notes)
            }
            guard let start = notes.compactMap(\.eventStart).first else { return nil }
            let title = notes.compactMap { $0.meta("event_title") }.first ?? "Meeting"
            return (CalendarEvent(id: id, title: title, start: start, end: start), notes)
        }
    }

    /// Replaces all scheduled reminders. Asks for permission the first time there is something to remind of.
    func schedule(_ meetings: [(event: CalendarEvent, notes: [Note])]) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        // iOS keeps at most 64 pending notifications; the next sync schedules the ones after these.
        let upcoming = meetings.filter { $0.event.start.addingTimeInterval(-Self.lead) > .now && !$0.notes.isEmpty }
            .sorted { $0.event.start < $1.event.start }.prefix(30)
        guard !upcoming.isEmpty, (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for (event, notes) in upcoming {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = "Starts in 5 minutes. Your notes: " + notes.map(\.title).joined(separator: ", ")
            content.sound = .default
            content.userInfo = ["note": notes[0].name]
            let at = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: event.start.addingTimeInterval(-Self.lead))
            try? await center.add(UNNotificationRequest(identifier: event.id, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: at, repeats: false)))
        }
    }

    // Shown even while the app is in front: that is where it usually is before a meeting.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let name = response.notification.request.content.userInfo["note"] as? String else { return }
        await MainActor.run { open?(name) }
    }
}
