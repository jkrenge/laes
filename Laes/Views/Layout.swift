import SwiftUI

// Pure layout helpers used by the week views (unit-tested in LayoutTests).

struct PlacedEvent {
    var event: CalendarEvent
    var column: Int
    var columnCount: Int
}

/// Cluster/column packing: each event takes the first free column; events that transitively
/// overlap form a cluster and share that cluster's column count.
func layoutEvents(_ events: [CalendarEvent]) -> [PlacedEvent] {
    var result: [PlacedEvent] = []
    var columnEnds: [Date] = []
    var clusterStart = 0
    var clusterEnd = Date.distantPast

    func closeCluster() {
        for i in clusterStart..<result.count { result[i].columnCount = columnEnds.count }
        columnEnds = []
        clusterStart = result.count
    }

    for event in events.sorted(by: { ($0.start, $1.end) < ($1.start, $0.end) }) {
        if event.start >= clusterEnd { closeCluster() }
        let column = columnEnds.firstIndex { $0 <= event.start } ?? columnEnds.count
        if column == columnEnds.count { columnEnds.append(event.end) } else { columnEnds[column] = event.end }
        result.append(PlacedEvent(event: event, column: column, columnCount: 0))
        clusterEnd = max(clusterEnd, event.end)
    }
    closeCluster()
    return result
}

/// Tasks shown in a day's to-do slot: due that day; overdue ones move to today. No due date → nowhere.
func tasksDue(on day: Date, from tasks: [TodoTask], today: Date, calendar: Calendar = .laes) -> [TodoTask] {
    let todayStart = calendar.startOfDay(for: today)
    let isToday = calendar.isDate(day, inSameDayAs: today)
    return tasks
        .filter { task in
            guard let due = task.due else { return false }
            return due < todayStart ? isToday : calendar.isDate(due, inSameDayAs: day)
        }
        .sorted { ($0.due!, $0.title) < ($1.due!, $1.title) }
}

/// Events drawn in the all-day strip instead of the time grid.
func isAllDayBar(_ event: CalendarEvent) -> Bool {
    event.isAllDay || event.end.timeIntervalSince(event.start) >= 86_400
}

struct AllDayBar {
    var event: CalendarEvent
    var startColumn: Int   // 0...6
    var endColumn: Int     // exclusive, 1...7
    var lane: Int
}

/// All-day/multi-day events clipped to the week starting at `weekStart`, packed into lanes.
func allDayBars(_ events: [CalendarEvent], weekStart: Date, calendar: Calendar = .laes) -> [AllDayBar] {
    func dayIndex(_ date: Date) -> Int {
        calendar.dateComponents([.day], from: weekStart, to: calendar.startOfDay(for: date)).day!
    }
    var laneEnds: [Int] = []
    return events
        .filter(isAllDayBar)
        .sorted { ($0.start, $1.end) < ($1.start, $0.end) }
        .compactMap { event in
            let start = max(0, dayIndex(event.start))
            let endDay = calendar.startOfDay(for: event.end)
            let end = min(7, dayIndex(event.end) + (event.end > endDay ? 1 : 0))
            guard end > start else { return nil }
            let lane = laneEnds.firstIndex { $0 <= start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
            return AllDayBar(event: event, startColumn: start, endColumn: end, lane: lane)
        }
}

#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif

/// Sizes that differ between pointer and touch.
enum Metrics {
    #if os(macOS)
    static let taskRow: CGFloat = 16, taskFont: CGFloat = 11, resizeHandle: CGFloat = 6
    #else
    static let taskRow: CGFloat = 21, taskFont: CGFloat = 13, resizeHandle: CGFloat = 22
    #endif
}

/// The hours a day's time grid shows (set in Settings), and where a time falls in a grid of a given height.
enum DayHours {
    static var firstHour: Int { UserDefaults.standard.object(forKey: "firstHour") as? Int ?? 7 }
    static var lastHour: Int { UserDefaults.standard.object(forKey: "lastHour") as? Int ?? 20 }

    /// shortcut: hours are measured from midnight in seconds, so DST-change days shift by an hour.
    static func y(for date: Date, dayStart: Date, height: CGFloat) -> CGFloat {
        let hours = date.timeIntervalSince(dayStart) / 3600 - Double(firstHour)
        return CGFloat(hours / Double(lastHour - firstHour)) * height
    }

    /// Clamped to the visible hours; events entirely outside become a 3pt sliver at the edge.
    static func verticalSpan(_ event: CalendarEvent, dayStart: Date, height: CGFloat) -> (y: CGFloat, height: CGFloat) {
        let top = y(for: event.start, dayStart: dayStart, height: height)
        let bottom = y(for: event.end, dayStart: dayStart, height: height)
        if bottom <= 0 { return (0, 3) }
        if top >= height { return (height - 3, 3) }
        let clampedTop = max(0, top)
        let blockHeight = max(14, min(height, bottom) - clampedTop)
        return (min(clampedTop, height - blockHeight), blockHeight)
    }
}

extension View {
    /// Details shown in a popover on the Mac, and in a bottom drawer on iOS.
    @ViewBuilder func detailsFrame(width: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width, alignment: .leading)
        #else
        ScrollView { frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14) }
            .presentationDetents([.medium, .large])
        #endif
    }
}

extension Color {
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Nonisolated: SwiftUI resolves the colour on its render thread during animations, and a main-actor
    /// closure there traps (the crash when adding a note from a meeting or deleting a list on iPhone).
    nonisolated static func dynamic(light: PlatformColor, dark: PlatformColor) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
        #else
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        #endif
    }

    /// parcelLab primary; white on it is ~7.6:1.
    /// Brand-coloured small text: the brand indigo is too dark on a dark background.
    static let brandText = dynamic(light: PlatformColor(red: 0x3D / 255, green: 0x3A / 255, blue: 0xD3 / 255, alpha: 1),
                                   dark: PlatformColor(red: 0.62, green: 0.61, blue: 1.0, alpha: 1))
    static let brand = Color(red: 0x3D / 255, green: 0x3A / 255, blue: 0xD3 / 255)
    /// Small secondary text; `.secondary` is ~3.9:1 on white, this stays above 4.5:1 in both modes.
    static let subtle = Color.primary.opacity(0.66)
    #if os(macOS)
    static let separator = Color(nsColor: .separatorColor)
    #else
    static let separator = Color(uiColor: .separator)
    #endif
    static let overdue = dynamic(light: PlatformColor(red: 0.70, green: 0.15, blue: 0.12, alpha: 1),
                                 dark: PlatformColor(red: 1.0, green: 0.45, blue: 0.42, alpha: 1))
    /// Tasks and notes sit on cards a step off the window's background: near-white, not white, in light mode.
    static let card = dynamic(light: PlatformColor(white: 0.985, alpha: 1), dark: PlatformColor(white: 0.19, alpha: 1))
    /// The window's background behind those cards, toolbar included.
    static let canvas = dynamic(light: PlatformColor(white: 0.935, alpha: 1), dark: PlatformColor(white: 0.12, alpha: 1))
    static let important = dynamic(light: PlatformColor(red: 0.70, green: 0.42, blue: 0.0, alpha: 1),
                                   dark: PlatformColor(red: 1.0, green: 0.79, blue: 0.26, alpha: 1))
}

extension AppStore {
    func color(for event: CalendarEvent) -> Color {
        event.categories.first.flatMap { categoryColors[$0] }.flatMap(Color.init(hex:)) ?? .brand
    }
}

#if os(macOS)
extension View {
    /// A card on the window's background, as Tasks' list and details and the open note use. No dividers around it.
    func card() -> some View {
        background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Floating glass, as on iPhone; frosted before macOS 26.
    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}
#endif

#if os(iOS)
/// A one-line field whose Return acts and keeps the keyboard up, for adding one item after another.
/// SwiftUI's fields always end editing on Return; focusing them again made the keyboard drop and come back.
/// Return on an empty field ends editing.
struct EntryField: UIViewRepresentable {
    let prompt: String
    @Binding var text: String
    var style: UIFont.TextStyle = .body
    var isEditing: Binding<Bool>?   // follows whether the field has the keyboard
    let onReturn: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = prompt
        field.font = .preferredFont(forTextStyle: style)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .next
        field.tintColor = UIColor(Color.brandText)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.placeholder = prompt
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: field.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EntryField
        init(parent: EntryField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

        func textFieldDidBeginEditing(_ field: UITextField) { parent.isEditing?.wrappedValue = true }
        func textFieldDidEndEditing(_ field: UITextField) { parent.isEditing?.wrappedValue = false }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            if parent.text.trimmingCharacters(in: .whitespaces).isEmpty { field.resignFirstResponder() } else { parent.onReturn() }
            return false
        }
    }
}

extension View {
    /// Floating glass like the tab bar.
    @ViewBuilder func glassCapsule() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}
#endif
