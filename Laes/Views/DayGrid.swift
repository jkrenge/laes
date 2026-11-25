import SwiftUI

/// One day's timed events between the visible hours. Dropping a task here blocks an hour for it, named
/// after the task; meetings made in lães can be resized from their bottom edge.
struct DayGrid: View {
    @Environment(AppStore.self) private var store
    let day: Date
    let width: CGFloat
    let height: CGFloat
    @State private var isTargeted = false
    @State private var resizing: (id: String, end: Date)?

    var body: some View {
        let dayEnd = Calendar.laes.date(byAdding: .day, value: 1, to: day)!
        let events = store.calendarEvents.filter { !isAllDayBar($0) && $0.start >= day && $0.start < dayEnd }
            .map { event in
                var event = event
                if let resizing, resizing.id == event.id { event.end = resizing.end }
                return event
            }
        let inset: CGFloat = 2
        let secondsPerPoint = Double(DayHours.lastHour - DayHours.firstHour) * 3600 / Double(max(height, 1))
        ZStack(alignment: .topLeading) {
            ForEach(layoutEvents(events), id: \.event.id) { placed in
                let span = DayHours.verticalSpan(placed.event, dayStart: day, height: height)
                let blockWidth = (width - 2 * inset) / CGFloat(placed.columnCount)
                EventBlock(event: placed.event, color: store.color(for: placed.event),
                           size: CGSize(width: blockWidth - 1, height: span.height))
                    .overlay(alignment: .bottom) {
                        if placed.event.isOwn { resizeHandle(placed.event.id, secondsPerPoint: secondsPerPoint) }
                    }
                    .offset(x: inset + CGFloat(placed.column) * blockWidth, y: span.y)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(isTargeted ? Color.brand.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, location in
            guard let task = store.tasks.first(where: { $0.id == ids.first }) else { return false }
            let seconds = Double(DayHours.firstHour) * 3600 + location.y * secondsPerPoint
            let start = day.addingTimeInterval((seconds / 1800).rounded(.down) * 1800)   // on the half hour
            Task { await store.addEvent(title: task.title, start: start) }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    /// Drag to change when the meeting ends, in 15-minute steps.
    private func resizeHandle(_ id: String, secondsPerPoint: Double) -> some View {
        Color.clear
            .frame(height: Metrics.resizeHandle)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            #endif
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    // The stored event, not the one on screen: that already includes this drag.
                    guard let event = store.events.first(where: { $0.id == id }) else { return }
                    let end = event.end.addingTimeInterval((drag.translation.height * secondsPerPoint / 900).rounded() * 900)
                    resizing = (id, max(end, event.start.addingTimeInterval(900)))
                }
                .onEnded { _ in
                    guard let resizing, let event = store.events.first(where: { $0.id == id }) else { return }
                    Task {
                        await store.setEnd(of: event, to: resizing.end)
                        self.resizing = nil
                    }
                })
            .accessibilityHidden(true)
    }
}
