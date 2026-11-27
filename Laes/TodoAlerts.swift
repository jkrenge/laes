import Foundation
import UserNotifications

/// The app icon's badge counts open to-dos due today or overdue; a notification each morning says how many there
/// are. Both are scheduled a week ahead from the tasks as they are now, and again whenever they change, so the badge
/// is right after midnight and the summary right at its time even if lães hasn't run since.
/// Only counts go out, no titles: the lock screen shows notifications, private lists included.
enum TodoAlerts {
    static let prefix = "todos-"   // its notifications; meeting reminders leave these alone
    static let days = 7

    /// Open to-dos on a day: due that day, and overdue by then.
    static func count(_ tasks: [TodoTask], on day: Date, calendar: Calendar = .laes) -> (today: Int, overdue: Int) {
        let start = calendar.startOfDay(for: day)
        let dated = tasks.compactMap(\.due)
        return (dated.filter { $0 == start }.count, dated.filter { $0 < start }.count)
    }

    static func summary(_ count: (today: Int, overdue: Int)) -> String {
        let today = count.today == 1 ? "1 to-do due today" : "\(count.today) to-dos due today"
        let overdue = "\(count.overdue) overdue"
        switch (count.today, count.overdue) {
        case (_, 0): return today
        case (0, _): return count.overdue == 1 ? "1 to-do is overdue" : "\(count.overdue) to-dos are overdue"
        default: return today + ", " + overdue
        }
    }

    /// Replaces its notifications and sets the badge. `morning`: minutes after midnight, or nil for no summary.
    static func schedule(_ tasks: [TodoTask], badge: Bool, morning: Int?, calendar: Calendar = .laes) async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard badge || morning != nil else {
            try? await center.setBadgeCount(0)
            return
        }
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        let total = { (count: (today: Int, overdue: Int)) in count.today + count.overdue }
        if badge { try? await center.setBadgeCount(total(count(tasks, on: .now, calendar: calendar))) }
        let today = calendar.startOfDay(for: .now)
        for offset in 0..<days {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let count = count(tasks, on: day, calendar: calendar)
            if badge, offset > 0 {   // at midnight, silently
                let content = UNMutableNotificationContent()
                content.badge = total(count) as NSNumber
                await add(content, "\(prefix)badge-\(offset)", at: day, calendar: calendar)
            }
            if let morning, total(count) > 0 {
                let at = calendar.date(byAdding: .minute, value: morning, to: day)!
                guard at > .now else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Today's to-dos"
                content.body = summary(count)
                content.sound = .default
                if badge { content.badge = total(count) as NSNumber }
                content.userInfo = ["todos": true]
                await add(content, "\(prefix)morning-\(offset)", at: at, calendar: calendar)
            }
        }
    }

    private static func add(_ content: UNNotificationContent, _ id: String, at date: Date, calendar: Calendar) async {
        let at = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content,
                                                                               trigger: UNCalendarNotificationTrigger(dateMatching: at, repeats: false)))
    }
}
