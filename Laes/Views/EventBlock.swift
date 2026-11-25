import SwiftUI

struct EventBlock: View {
    let event: CalendarEvent
    let color: Color
    let size: CGSize
    @State private var showDetails = false

    private var isTentative: Bool { event.showAs == .tentative || event.response == .tentativelyAccepted }
    private var isDimmed: Bool { event.isCancelled || event.response == .declined }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 4, style: .continuous) }

    var body: some View {
        if event.isRedacted { hidden } else { meeting }
    }

    /// A private meeting while the private group is hidden: the time is taken, and nothing says what for.
    private var hidden: some View {
        HStack(spacing: 0) {
            if size.height >= 10 {
                Image(systemName: "eye.slash").font(.system(size: 10, weight: .semibold)).padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, size.height >= 18 ? 3 : 0)
        .frame(width: max(size.width, 0), height: size.height, alignment: .topLeading)
        .foregroundStyle(Color.subtle)
        .background(event.showAs == .free ? Color.clear : Color.primary.opacity(0.2), in: shape)
        .overlay { if event.showAs == .free { shape.strokeBorder(Color.primary.opacity(0.3), lineWidth: 1) } }
        .opacity(isDimmed ? 0.5 : 1)
        .help("Private")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Private, \(timeRangeText(event))")
    }

    private var meeting: some View {
        Button { showDetails = true } label: { content }
            .buttonStyle(.plain)
            .opacity(isDimmed ? 0.5 : 1)
            .help(event.title)
            .accessibilityLabel("\(event.title), \(timeRangeText(event))\(event.location.map { ", \($0)" } ?? ""), \(statusText(event))")
            .popover(isPresented: $showDetails, arrowEdge: .trailing) { EventDetails(event: event, color: color) }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            leadingBar.frame(width: 3)
            if size.height >= 10 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title)
                        .font(.system(size: 11, weight: .semibold))
                        .strikethrough(isDimmed)
                    if size.height >= 30, let location = event.location {
                        Text(location).font(.system(size: 11)).foregroundStyle(Color.subtle)
                    }
                }
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.leading, 4)
                .padding(.top, size.height >= 18 ? 2 : 0)
                Spacer(minLength: 0)
                if size.width >= 90 { icons }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: max(size.width, 0), height: size.height, alignment: .topLeading)
        .background(fill, in: shape)
        .overlay { if event.showAs == .free { shape.strokeBorder(color, lineWidth: 1) } }
        .clipShape(shape)
        .contentShape(shape)
    }

    private var fill: Color {
        switch event.showAs {
        case .free: .clear
        case .oof: Color.gray.opacity(0.28)
        default: color.opacity(isTentative ? 0.09 : 0.18)
        }
    }

    @ViewBuilder private var leadingBar: some View {
        if isTentative {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.3)))
                var stripes = Path()
                var y: CGFloat = 0
                while y < size.height + size.width {
                    stripes.move(to: CGPoint(x: 0, y: y))
                    stripes.addLine(to: CGPoint(x: size.width, y: y - size.width))
                    y += 4
                }
                ctx.stroke(stripes, with: .color(color), lineWidth: 1.5)
            }
        } else {
            color
        }
    }

    private var icons: some View {
        HStack(spacing: 3) {
            if event.isPrivate { Image(systemName: "lock.fill") }
            if event.isRecurring { Image(systemName: "arrow.triangle.2.circlepath") }
            if event.isOnlineMeeting { Image(systemName: "video.fill") }
        }
        .font(.system(size: 8))
        .foregroundStyle(Color.subtle)
        .padding(.top, min(4, max(0, (size.height - 10) / 2)))
        .padding(.trailing, 4)
        .accessibilityHidden(true)
    }
}

struct EventDetails: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let event: CalendarEvent
    let color: Color

    private func open(_ note: Note) {
        store.openNote = note.name   // the app shell switches to Notes
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(event.title).font(.headline).strikethrough(event.isCancelled || event.response == .declined)
            }
            Group {
                Label(timeRangeText(event), systemImage: "clock")
                if let location = event.location { Label(location, systemImage: "mappin.and.ellipse") }
                if !event.categories.isEmpty { Label(event.categories.joined(separator: ", "), systemImage: "tag") }
                Label(statusText(event), systemImage: "person.crop.circle.badge.questionmark")
                if event.isPrivate { Label("Private", systemImage: "lock.fill") }
                if event.isRecurring { Label("Recurring", systemImage: "arrow.triangle.2.circlepath") }
                if event.isOnlineMeeting { Label("Online meeting", systemImage: "video.fill") }
            }
            .font(.callout)
            if !event.attendees.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(event.attendees.prefix(8), id: \.self) { Text($0) }
                    if event.attendees.count > 8 {
                        Text("+\(event.attendees.count - 8) more").foregroundStyle(Color.subtle)
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Attendees: " + event.attendees.joined(separator: ", "))
            }
            if store.notesReady {
                Divider()
                ForEach(store.notes(for: event)) { note in
                    Button { open(note) } label: {
                        HStack {
                            Label(note.title, systemImage: "note.text").lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.subtle).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { open(store.addNote(title: event.title, event: event)) } label: {
                    Label("Add Note", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("A note linked to this meeting; you are reminded of it five minutes before")
            }
            if let url = event.joinURL {
                Link(destination: url) { Label("Join", systemImage: "video.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brand)
                    .padding(.top, 2)
            }
            if event.isOwn {
                Button(role: .destructive) {
                    Task { await store.deleteEvent(event) }
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Moves the meeting to Deleted Items in Outlook")
            }
            if let url = event.webLink {
                Link(destination: url) { Label("Open in Outlook", systemImage: "arrow.up.right.square") }
                    .font(.callout)
                    .padding(.top, 2)
            }
        }
        .textSelection(.enabled)
        .padding(16)
        .detailsFrame(width: 290)
    }
}

func timeRangeText(_ event: CalendarEvent) -> String {
    let cal = Calendar.laes
    let day = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
    let time = Date.FormatStyle(date: .omitted, time: .shortened)
    if event.isAllDay {
        let last = event.end.addingTimeInterval(-1)
        return cal.isDate(event.start, inSameDayAs: last)
            ? "\(event.start.formatted(day)), all day"
            : "\(event.start.formatted(day)) – \(last.formatted(day))"
    }
    if cal.isDate(event.start, inSameDayAs: event.end) {
        return "\(event.start.formatted(day)), \(event.start.formatted(time)) – \(event.end.formatted(time))"
    }
    return "\(event.start.formatted(day)) \(event.start.formatted(time)) – \(event.end.formatted(day)) \(event.end.formatted(time))"
}

func statusText(_ event: CalendarEvent) -> String {
    if event.isCancelled { return "Cancelled" }
    switch event.response {
    case .declined: return "Declined"
    case .tentativelyAccepted: return "Tentatively accepted"
    default: break
    }
    switch event.showAs {
    case .free: return "Free"
    case .tentative: return "Tentative"
    case .oof: return "Out of office"
    case .workingElsewhere: return "Working elsewhere"
    case .busy, .unknown: return "Busy"
    }
}
