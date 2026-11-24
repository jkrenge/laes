import SwiftUI

/// A sticker for the app icon. The tildes and the name go on one diagonal (top left, bottom right), the small stickers
/// on the other; a corner takes one sticker or stays empty, each sticker once, one tilde at most: 143 designs.
/// Scripts/make-icon.swift draws every design (each is built into the iPhone app) and lists the same stickers and codes.
enum Sticker: String, CaseIterable, Identifiable {
    case yellowTilde, whiteTilde, page, tick, notepad, name
    var id: Self { self }

    var isTilde: Bool { self == .yellowTilde || self == .whiteTilde }
    var corners: [Corner] { [.yellowTilde, .whiteTilde, .name].contains(self) ? [.topLeft, .bottomRight] : [.topRight, .bottomLeft] }

    /// Names the iPhone icons, so it must match the script's.
    var code: Character { Array("ywptnl")[Self.allCases.firstIndex(of: self)!] }

    var title: String {
        switch self {
        case .yellowTilde: "Yellow tilde"
        case .whiteTilde: "White tilde"
        case .page: "Calendar page"
        case .tick: "Tick"
        case .notepad: "Notepad"
        case .name: "Name"
        }
    }

    var image: Image { Image("Sticker-\(rawValue)") }
}

enum Corner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .topLeft: "top left"
        case .topRight: "top right"
        case .bottomLeft: "bottom left"
        case .bottomRight: "bottom right"
        }
    }
}

/// Which sticker sits in which corner of the app icon.
struct IconDesign: Equatable {
    private(set) var stickers: [Corner: Sticker]

    static let standard = IconDesign(stickers: [.topLeft: .yellowTilde, .topRight: .page, .bottomLeft: .tick, .bottomRight: .name])

    init(stickers: [Corner: Sticker]) { self.stickers = stickers }

    /// One character per corner in `Corner`'s order, "0" for an empty one, as the script names the icons.
    init?(code: String) {
        guard code.count == Corner.allCases.count else { return nil }
        var stickers: [Corner: Sticker] = [:]
        for (corner, character) in zip(Corner.allCases, code) where character != "0" {
            guard let sticker = Sticker.allCases.first(where: { $0.code == character }) else { return nil }
            stickers[corner] = sticker
        }
        self.stickers = stickers
    }

    var code: String { String(Corner.allCases.map { stickers[$0]?.code ?? "0" }) }

    /// This design's icon in the iPhone app; nil is the main one.
    var iconName: String? { self == .standard ? nil : "AppIcon-" + code }

    func corner(of sticker: Sticker) -> Corner? { stickers.first { $0.value == sticker }?.key }

    /// Puts a sticker in one of its corners, taking it from wherever it was, along with the other tilde.
    /// Moved from corner `old`, it swaps with the sticker it lands on.
    mutating func place(_ sticker: Sticker, at corner: Corner, from old: Corner? = nil) {
        let occupant = stickers[corner]
        stickers = stickers.filter { $0.value != sticker && !($0.value.isTilde && sticker.isTilde) }
        stickers[corner] = sticker
        if let old, old != corner, let occupant, occupant != sticker, !(occupant.isTilde && sticker.isTilde) { stickers[old] = occupant }
    }

    /// Into its first free corner, or else its first.
    mutating func add(_ sticker: Sticker) {
        place(sticker, at: sticker.corners.first { stickers[$0] == nil } ?? sticker.corners[0])
    }

    mutating func remove(_ sticker: Sticker) { stickers = stickers.filter { $0.value != sticker } }

    /// The icon in use: on iPhone the one iOS shows, on the Mac the one last saved on this Mac.
    /// Nil for one this version doesn't have (saved before the corners), so Save can replace it.
    static var saved: IconDesign? {
        #if os(iOS)
        let code = UIApplication.shared.alternateIconName?.replacingOccurrences(of: "AppIcon-", with: "")
        #else
        let code = UserDefaults.standard.string(forKey: "iconDesign")
        #endif
        return code.map(IconDesign.init(code:)) ?? .standard
    }

    /// Makes this the app's icon. iOS confirms with an alert of its own; the Mac shows it in the Dock while lães runs.
    func apply() async throws {
        #if os(iOS)
        try await UIApplication.shared.setAlternateIconName(iconName)
        #else
        UserDefaults.standard.set(code, forKey: "iconDesign")
        showInDock()
        #endif
    }

    #if os(macOS)
    /// macOS only lets a running app change its Dock icon; Finder and Launchpad keep the built-in one.
    func showInDock() {
        guard self != .standard else { NSApp.applicationIconImage = nil; return }
        let renderer = ImageRenderer(content: IconPicture(design: self, side: 512))
        renderer.scale = 2
        NSApp.applicationIconImage = renderer.nsImage
    }
    #endif
}

/// The icon with a design's stickers, as the platform shows it: on the Mac the plate with its shape and shadow,
/// on iPhone full bleed (iOS rounds the corners).
struct IconPicture: View {
    let design: IconDesign
    let side: CGFloat
    var ghosts = false   // faint outlines in empty corners
    var target: Sticker?   // being dragged: outlines where it can go
    var aim: Corner?   // the corner it would land in: its outline is strongest, the sticker there fades
    var hidden: Corner?   // where the dragged sticker was picked up

    /// The square the stickers are laid out in.
    static func area(_ side: CGFloat) -> CGRect {
        #if os(macOS)
        CGRect(x: side * 100 / 1024, y: side * 100 / 1024, width: side * 824 / 1024, height: side * 824 / 1024)
        #else
        CGRect(x: 0, y: 0, width: side, height: side)
        #endif
    }

    static func rect(of sticker: Sticker, at corner: Corner, side: CGFloat) -> CGRect {
        let area = area(side), p = sticker.picture, c = corner.centre
        return CGRect(x: area.minX + (c.x + p.minX) * area.width, y: area.minY + (c.y + p.minY) * area.height,
                      width: p.width * area.width, height: p.height * area.height)
    }

    var body: some View {
        ZStack {
            #if os(macOS)
            Image("IconPlateMac").resizable()
            #else
            Image("IconPlate").resizable()
            #endif
            if ghosts {
                ForEach(Corner.allCases, id: \.self) { corner in
                    if let target {
                        if target.corners.contains(corner) { ghost(target, corner, opacity: corner == aim ? 0.6 : 0.25) }
                    } else if design.stickers[corner] == nil, let usual = IconDesign.standard.stickers[corner] {
                        ghost(usual, corner, opacity: 0.2)
                    }
                }
            }
            ForEach(Corner.allCases, id: \.self) { corner in
                if let sticker = design.stickers[corner] {
                    place(sticker.image.resizable(), sticker, corner)
                        .opacity(corner == hidden ? 0 : corner == aim && sticker != target ? 0.35 : 1)
                }
            }
        }
        .frame(width: side, height: side)
    }

    private func ghost(_ sticker: Sticker, _ corner: Corner, opacity: Double) -> some View {
        place(sticker.image.renderingMode(.template).resizable(), sticker, corner).foregroundStyle(.white.opacity(opacity))
    }

    private func place(_ image: some View, _ sticker: Sticker, _ corner: Corner) -> some View {
        let rect = Self.rect(of: sticker, at: corner, side: side)
        return image.frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
}

/// Settings › App Icon: a sticker dragged onto the icon snaps into the nearer of its two corners; dragged off, it comes away.
/// Save applies the design.
struct IconEditor: View {
    @State private var design = IconDesign.saved ?? .standard
    @State private var saved = IconDesign.saved
    @State private var drag: Drag?
    @State private var iconArea = CGRect.zero   // the stickers' square, in the editor's space
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Drag {
        var sticker: Sticker
        var location: CGPoint
        var grab: CGSize   // pointer to the picture's centre
        var from: Corner?   // picked up off the icon
        var landing = false
    }

    #if os(macOS)
    private let side: CGFloat = 240, cell: CGFloat = 40
    #else
    private let side: CGFloat = 260, cell: CGFloat = 40
    #endif

    var body: some View {
        VStack(spacing: 28) {
            icon
            tray
            HStack(spacing: 12) {
                Button("Reset") { withAnimation(.snappy) { design = .standard } }
                    .disabled(design == .standard)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brand)
                    .disabled(design == saved)
            }
            #if os(iOS)
            .controlSize(.large)
            #endif
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.overdue)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named("editor"))
        .overlay { floating }
    }

    private var icon: some View {
        IconPicture(design: design, side: side, ghosts: true, target: drag?.sticker,
                    aim: drag.flatMap { $0.landing || iconArea.insetBy(dx: -24, dy: -24).contains($0.location) ? nearest($0) : nil },
                    hidden: drag?.from)
            #if os(iOS)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            #endif
            .overlay {
                ForEach(Corner.allCases, id: \.self) { corner in
                    if let sticker = design.stickers[corner] {
                        let rect = IconPicture.rect(of: sticker, at: corner, side: side)
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: rect.width * 0.8, height: rect.height * 0.8)   // the picture's edges are its shadow
                            .position(x: rect.midX, y: rect.midY)
                            .gesture(dragging(sticker, from: corner))
                    }
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("editor")) } action: { frame in
                iconArea = IconPicture.area(side).offsetBy(dx: frame.minX, dy: frame.minY)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("App icon")
            .accessibilityValue(design.stickers.isEmpty ? "No stickers" : Corner.allCases.compactMap { corner in
                design.stickers[corner].map { "\($0.title) \(corner.title)" }
            }.formatted())
    }

    /// Every sticker; the ones on the icon are faded. Tapping one puts it on or takes it off.
    private var tray: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Sticker.allCases) { sticker in
                    let on = design.corner(of: sticker) != nil
                    sticker.image.resizable().scaledToFit()
                        .frame(width: cell, height: cell)
                        .padding(4)
                        .opacity(on || drag?.sticker == sticker ? 0.3 : 1)
                        .contentShape(Rectangle())
                        .gesture(dragging(sticker, from: nil))
                        .onTapGesture { withAnimation(.snappy) { toggle(sticker) } }
                        .help(sticker.title)
                        .accessibilityElement()
                        .accessibilityLabel(sticker.title)
                        .accessibilityValue(design.corner(of: sticker).map { "On the icon, \($0.title)" } ?? "")
                        .accessibilityHint(on ? "Takes it off the icon" : "Puts it on the icon")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { toggle(sticker) }
                        .accessibilityActions {
                            if let corner = design.corner(of: sticker), let other = sticker.corners.first(where: { $0 != corner }) {
                                Button("Move to \(other.title)") { design.place(sticker, at: other, from: corner) }
                            }
                        }
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Drag a sticker onto the icon and it snaps into the nearer of its two corners. Drag it off to take it away.")
                .font(.footnote)
                .foregroundStyle(Color.subtle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)   // with .fixedSize, this text made the Mac's settings hide their sidebar
        }
    }

    /// The sticker under the pointer while dragging, at the icon's scale and lifted a little.
    @ViewBuilder private var floating: some View {
        if let drag {
            let rect = IconPicture.rect(of: drag.sticker, at: .topLeft, side: side)   // only its size
            drag.sticker.image.resizable()
                .frame(width: rect.width, height: rect.height)
                .scaleEffect(drag.landing ? 1 : 1.08)
                .shadow(color: .black.opacity(drag.landing ? 0 : 0.25), radius: 12, y: 8)
                .position(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
                .allowsHitTesting(false)
        }
    }

    private func toggle(_ sticker: Sticker) {
        if design.corner(of: sticker) != nil { design.remove(sticker) } else { design.add(sticker) }
    }

    private func dragging(_ sticker: Sticker, from corner: Corner?) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("editor"))
            .onChanged { value in
                if drag == nil {
                    let home = corner.map { home(of: sticker, at: $0) } ?? value.startLocation
                    drag = Drag(sticker: sticker, location: value.location,
                                grab: CGSize(width: value.startLocation.x - home.x, height: value.startLocation.y - home.y), from: corner)
                }
                drag?.location = value.location
            }
            .onEnded { value in drop(at: value.location) }
    }

    /// Dropped on (or near) the icon, the sticker flies into the nearer of its corners; dropped elsewhere, it comes off.
    private func drop(at location: CGPoint) {
        guard var drag else { return }
        drag.location = location
        let onIcon = iconArea.insetBy(dx: -24, dy: -24).contains(location)
        let corner = nearest(drag)
        guard onIcon, !reduceMotion else {
            withAnimation(.snappy) {
                if onIcon { design.place(drag.sticker, at: corner, from: drag.from) } else if drag.from != nil { design.remove(drag.sticker) }
                self.drag = nil
            }
            return
        }
        let home = home(of: drag.sticker, at: corner)
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
            self.drag?.location = CGPoint(x: home.x + drag.grab.width, y: home.y + drag.grab.height)
            self.drag?.landing = true
        } completion: {
            design.place(drag.sticker, at: corner, from: drag.from)
            self.drag = nil
        }
    }

    /// The dragged sticker's corner closest to where its picture is.
    private func nearest(_ drag: Drag) -> Corner {
        let at = CGPoint(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
        return drag.sticker.corners.min { hypot(home(of: drag.sticker, at: $0).x - at.x, home(of: drag.sticker, at: $0).y - at.y)
            < hypot(home(of: drag.sticker, at: $1).x - at.x, home(of: drag.sticker, at: $1).y - at.y) }!
    }

    /// The picture's centre in a corner, in the editor's space.
    private func home(of sticker: Sticker, at corner: Corner) -> CGPoint {
        let p = sticker.picture, c = corner.centre
        return CGPoint(x: iconArea.minX + (c.x + p.midX) * iconArea.width, y: iconArea.minY + (c.y + p.midY) * iconArea.height)
    }

    private func save() async {
        do {
            try await design.apply()
            saved = design
            error = nil
        } catch {
            self.error = "Couldn't change the icon: \(error.localizedDescription)"
        }
    }
}
