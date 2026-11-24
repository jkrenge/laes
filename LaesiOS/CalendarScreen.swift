import SwiftUI

/// Three days across, with the same three days of the following week underneath. Scrolls sideways one
/// day at a time; each row keeps a readable height and the page scrolls vertically instead.
struct CalendarScreen: View {
    @Environment(AppStore.self) private var store
    @State private var leading: Date?   // leftmost visible day
    @State private var days: [Date] = []

    static let gutter: CGFloat = 34
    static let hourHeight: CGFloat = 40
    static let headerHeight: CGFloat = 34
    static let allDayHeight: CGFloat = 44
    static var todoHeight: CGFloat { 3 * (Metrics.taskRow + 1) + 8 }
    static var gridHeight: CGFloat { CGFloat(DayHours.lastHour - DayHours.firstHour) * hourHeight }

    private var today: Date { Calendar.laes.startOfDay(for: .now) }

    var body: some View {
        TimelineView(.everyMinute) { context in
            GeometryReader { geo in
                let column = floor((geo.size.width - Self.gutter) / (geo.size.width > 700 ? 7 : 3))
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            hourLabels
                            Color.clear.frame(height: 2)
                            hourLabels
                        }
                        .frame(width: Self.gutter)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 0) {
                                ForEach(days, id: \.self) { day in
                                    VStack(spacing: 0) {
                                        DayCell(day: day, width: column, now: context.date)
                                        Color.primary.opacity(0.28).frame(height: 2)   // between this week and the next
                                        DayCell(day: Calendar.laes.date(byAdding: .day, value: 7, to: day)!, width: column, now: context.date)
                                    }
                                    .frame(width: column)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollPosition(id: $leading, anchor: .leading)
                        .scrollIndicators(.hidden)
                    }
                }
                .refreshable { await store.refresh() }
            }
        }
        .navigationTitle((leading ?? today).formatted(.dateTime.month(.abbreviated).year()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Today") { withAnimation { leading = today } }
            }
        }
        .onAppear {
            guard days.isEmpty else { return }
            // shortcut: a fixed window of days around today, not endless; widen it if anyone plans further out.
            days = (-120...400).map { Calendar.laes.date(byAdding: .day, value: $0, to: today)! }
            leading = today
        }
        .onChange(of: leading) { _, day in
            if let day { store.show(day: day) }
        }
        .id([store.firstHour, store.lastHour])
    }

    /// Hour numbers beside one row's time grid, under blank space the height of its header, tasks and all-day strip.
    private var hourLabels: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.headerHeight + Self.todoHeight + Self.allDayHeight + 3)
            ZStack(alignment: .topTrailing) {
                ForEach(DayHours.firstHour + 1 ..< DayHours.lastHour, id: \.self) { hour in
                    Text(String(format: "%02d", hour))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.subtle)
                        .offset(y: CGFloat(hour - DayHours.firstHour) * Self.hourHeight - 6)
                }
            }
            .frame(width: Self.gutter - 6, height: Self.gridHeight, alignment: .topTrailing)
            .accessibilityHidden(true)
        }
    }
}

/// One day in one row: date, tasks due, all-day events, then the time grid.
private struct DayCell: View {
    @Environment(AppStore.self) private var store
    let day: Date
    let width: CGFloat
    let now: Date

    var body: some View {
        let cal = Calendar.laes
        let isToday = cal.isDate(day, inSameDayAs: now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: day)!
        let allDay = store.visibleEvents.filter { isAllDayBar($0) && $0.start < dayEnd && $0.end > day }
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(day.formatted(.dateTime.weekday(.abbreviated))).foregroundStyle(isToday ? Color.primary : Color.subtle)
                Text(day.formatted(.dateTime.day()))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : Color.primary)
                    .frame(minWidth: 24, minHeight: 24)
                    .background { if isToday { Capsule().fill(Color.brand) } }
            }
            .font(.system(size: 13, weight: isToday ? .semibold : .regular))
            .padding(.leading, 8)
            .frame(width: width, height: CalendarScreen.headerHeight, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((isToday ? "Today, " : "") + day.formatted(date: .complete, time: .omitted))
            .accessibilityAddTraits(.isHeader)
            Divider()
            TodoSlot(day: day, now: now).frame(height: CalendarScreen.todoHeight)
            Divider()
            VStack(spacing: 2) {
                ForEach(allDay.prefix(allDay.count > 2 ? 1 : 2)) { event in
                    EventBlock(event: event, color: store.color(for: event), size: CGSize(width: width - 4, height: 18))
                }
                if allDay.count > 2 {
                    Text("+\(allDay.count - 1) more").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.subtle)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                }
            }
            .padding(.top, 3)
            .frame(height: CalendarScreen.allDayHeight, alignment: .top)
            Divider()
            DayGrid(day: day, width: width, height: CalendarScreen.gridHeight)
                .background(alignment: .top) { hourLines }
                .overlay(alignment: .top) { if isToday { nowLine } }
        }
        .background(isToday ? Color.brand.opacity(0.06) : cal.isDateInWeekend(day) ? Color.primary.opacity(0.03) : Color.clear)
        .overlay(alignment: .leading) { Color.separator.frame(width: 0.5) }
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(DayHours.firstHour ..< DayHours.lastHour, id: \.self) { _ in
                Color.clear.frame(height: CalendarScreen.hourHeight).overlay(alignment: .bottom) { Color.separator.opacity(0.6).frame(height: 0.5) }
            }
        }
    }

    @ViewBuilder private var nowLine: some View {
        let y = DayHours.y(for: now, dayStart: day, height: CalendarScreen.gridHeight)
        if y >= 0, y <= CalendarScreen.gridHeight {
            Rectangle().fill(.red).frame(height: 1.5).offset(y: y).accessibilityHidden(true)
        }
    }
}
