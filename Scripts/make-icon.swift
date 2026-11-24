// Renders the app icon: stickers (the two lanes of "≈", today's date, a tick, the name)
// on an azure plate ruled into a week. Also every other design the App Icon settings offer:
// each as an iPhone alternate icon, plus the plate and stickers as layers for the settings' editor.
// Run from the repo root:  swift Scripts/make-icon.swift
import AppKit
import CoreImage

func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let ink = rgb(0x111114), warm = rgb(0xFFC943)
let S: CGFloat = 1024
let P = NSRect(x: 100, y: 100, width: 824, height: 824)   // macOS icon grid plate
let C = NSPoint(x: P.midX, y: P.midY)
func X(_ f: CGFloat) -> CGFloat { P.minX + f * P.width }
func Y(_ f: CGFloat) -> CGFloat { P.minY + f * P.height }
let ci = CIContext()

// MARK: The tilde

/// One tilde: two equal circular arcs meeting in the middle with the same tangent, the second the first turned 180°,
/// so the wave has exact rotational symmetry. `phi` sets how steep the middle is, `tip` how far each end curls.
struct Wave { let c1: NSPoint, c2: NSPoint, r: CGFloat }
let phi: CGFloat = 34, tip: CGFloat = 150
var waves: [ObjectIdentifier: Wave] = [:]
func dir(_ deg: CGFloat) -> NSPoint { NSPoint(x: cos(deg * .pi / 180), y: sin(deg * .pi / 180)) }
func at(_ c: NSPoint, _ r: CGFloat, _ deg: CGFloat) -> NSPoint { let d = dir(deg); return NSPoint(x: c.x + d.x * r, y: c.y + d.y * r) }
func tilde(_ cx: CGFloat, _ cy: CGFloat, width: CGFloat) -> NSBezierPath {
    let r = width / (2 * (cos(phi * .pi / 180) - cos(tip * .pi / 180)))
    let m = dir(phi)
    let w = Wave(c1: NSPoint(x: cx - m.x * r, y: cy - m.y * r), c2: NSPoint(x: cx + m.x * r, y: cy + m.y * r), r: r)
    let p = NSBezierPath()
    p.move(to: at(w.c1, r, tip))
    p.appendArc(withCenter: w.c1, radius: r, startAngle: tip, endAngle: phi, clockwise: true)
    p.appendArc(withCenter: w.c2, radius: r, startAngle: phi + 180, endAngle: tip + 180, clockwise: false)
    waves[ObjectIdentifier(p)] = w
    return p
}
/// The ≈: two equal lanes.
func lanes(_ c: NSPoint, scale: CGFloat) -> [NSBezierPath] {
    [tilde(c.x, c.y + 100 * scale, width: 430 * scale), tilde(c.x, c.y - 100 * scale, width: 430 * scale)]
}
/// The exact outline of a lane `width` wide: concentric arcs and two round caps, one closed shape.
func outline(_ path: NSBezierPath, _ width: CGFloat) -> NSBezierPath {
    let w = waves[ObjectIdentifier(path)]!, r = w.r, h = width / 2
    let e1 = at(w.c1, r, tip), e2 = at(w.c2, r, tip + 180)
    let o = NSBezierPath()
    o.move(to: at(w.c1, r + h, tip))
    o.appendArc(withCenter: w.c1, radius: r + h, startAngle: tip, endAngle: phi, clockwise: true)
    o.appendArc(withCenter: w.c2, radius: r - h, startAngle: phi + 180, endAngle: tip + 180, clockwise: false)
    o.appendArc(withCenter: e2, radius: h, startAngle: tip + 360, endAngle: tip + 180, clockwise: true)
    o.appendArc(withCenter: w.c2, radius: r + h, startAngle: tip + 180, endAngle: phi + 180, clockwise: true)
    o.appendArc(withCenter: w.c1, radius: r - h, startAngle: phi, endAngle: tip, clockwise: false)
    o.appendArc(withCenter: e1, radius: h, startAngle: tip + 180, endAngle: tip, clockwise: true)
    o.close()
    return o
}
/// Filled area of thick lanes (for the sticker's white margin).
func union(_ paths: [NSBezierPath], _ width: CGFloat) -> NSBezierPath {
    let u = NSBezierPath()
    paths.forEach { u.append(NSBezierPath(cgPath: $0.cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))) }
    u.windingRule = .nonZero
    return u
}

// MARK: Drawing helpers

func stroke(_ p: NSBezierPath, _ c: NSColor, _ w: CGFloat) { c.setStroke(); p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke() }
func rr(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }
func oval(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
func moved(_ p: NSBezierPath, _ dy: CGFloat) -> NSBezierPath {
    let c = p.copy() as! NSBezierPath; c.transform(using: AffineTransform(translationByX: 0, byY: dy)); return c
}
func clipped(_ p: NSBezierPath, _ body: () -> Void) { NSGraphicsContext.saveGraphicsState(); p.addClip(); body(); NSGraphicsContext.restoreGraphicsState() }
func rotated(_ degrees: CGFloat, around c: NSPoint, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: c.x, yBy: c.y); t.rotate(byDegrees: degrees); t.translateX(by: -c.x, yBy: -c.y); t.concat()
    body(); NSGraphicsContext.restoreGraphicsState()
}
func newRep(_ pixels: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}
/// Draws `body` on its own layer, blurs it, and lays it into the current context.
func blurred(_ sigma: CGFloat, _ body: () -> Void) {
    let rep = newRep(Int(S))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep); body(); NSGraphicsContext.restoreGraphicsState()
    let img = CIImage(cgImage: rep.cgImage!).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
    NSGraphicsContext.current!.cgContext.draw(ci.createCGImage(img, from: img.extent)!, in: CGRect(x: 0, y: 0, width: S, height: S))
}
/// The soft shadow every sticker casts.
func dropShadow(_ edge: NSBezierPath) { blurred(10) { rgb(0x000000, 0.35).setFill(); moved(edge, -10).fill() } }
func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont(descriptor: NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.rounded)!, size: size)!
}
func text(_ s: String, _ font: NSFont, _ color: NSColor, at c: NSPoint, outline: CGFloat = 0) {
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if outline != 0 { attributes[.strokeColor] = color; attributes[.strokeWidth] = outline }
    let t = NSAttributedString(string: s, attributes: attributes)
    let box = t.boundingRect(with: .zero, options: [.usesDeviceMetrics])
    t.draw(at: NSPoint(x: c.x - box.midX, y: c.y - box.midY))
}

// MARK: The icon

/// Must match `Sticker` and `Corner` in the app (Laes/Views/IconEditor.swift), codes included: they name the iPhone icons.
enum Sticker: String, CaseIterable {
    case yellowTilde, whiteTilde, page, tick, notepad, name
    var code: String { ["y", "w", "p", "t", "n", "l"][Self.allCases.firstIndex(of: self)!] }
    var isTilde: Bool { self == .yellowTilde || self == .whiteTilde }
    /// The tildes and the name share one diagonal, the small stickers the other.
    var corners: [Corner] { [.yellowTilde, .whiteTilde, .name].contains(self) ? [.topLeft, .bottomRight] : [.topRight, .bottomLeft] }
}
enum Corner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    /// Where a sticker's centre goes, in fractions of the plate (y up).
    var centre: NSPoint {
        switch self {
        case .topLeft: NSPoint(x: 0.34, y: 0.70)
        case .topRight: NSPoint(x: 0.70, y: 0.66)
        case .bottomLeft: NSPoint(x: 0.30, y: 0.30)
        case .bottomRight: NSPoint(x: 0.67, y: 0.28)
        }
    }
}
typealias Design = [Corner: Sticker]
let standard: Design = [.topLeft: .yellowTilde, .topRight: .page, .bottomLeft: .tick, .bottomRight: .name]
/// One character per corner, in Corner's order; "0" is an empty corner.
func iconName(_ d: Design) -> String? { d == standard ? nil : "AppIcon-" + Corner.allCases.map { d[$0]?.code ?? "0" }.joined() }
/// Every design: on each diagonal, either corner takes one of its stickers or stays empty; each sticker once, one tilde at most.
func allDesigns() -> [Design] {
    func pairs(_ a: Corner, _ b: Corner, _ options: [Sticker]) -> [Design] {
        let choices: [Sticker?] = [nil] + options
        return choices.flatMap { x in choices.compactMap { y -> Design? in
            if let x, let y, x == y || (x.isTilde && y.isTilde) { return nil }
            var d = Design(); d[a] = x; d[b] = y; return d
        } }
    }
    let wide = pairs(.topLeft, .bottomRight, [.yellowTilde, .whiteTilde, .name])
    let small = pairs(.topRight, .bottomLeft, [.page, .tick, .notepad])
    return wide.flatMap { w in small.map { w.merging($0) { a, _ in a } } }
}

/// Azure ruled into a week: seven days, two lanes, the weekend the week opens with tinted.
func drawPlate() {
    NSGradient(colors: [rgb(0x4A90F7), rgb(0x2563EB), rgb(0x1D4ED8)])!.draw(in: P, angle: -90)
    let column = P.width / 7
    rgb(0xFFFFFF, 0.08).setFill(); NSRect(x: P.minX, y: P.minY, width: column * 2, height: P.height).fill()
    rgb(0xFFFFFF, 0.16).setFill()
    for i in 1..<7 { NSRect(x: P.minX + column * CGFloat(i) - 2, y: P.minY, width: 4, height: P.height).fill() }
    NSRect(x: P.minX, y: C.y - 3, width: P.width, height: 6).fill()
}

func drawSticker(_ sticker: Sticker, at corner: Corner) {
    let c = NSPoint(x: X(corner.centre.x), y: Y(corner.centre.y))
    switch sticker {
    case .yellowTilde, .whiteTilde:
        rotated(-10, around: c) {   // the lanes
            let l = lanes(c, scale: 0.5)
            let edge = union(l, 56 + 44)
            dropShadow(edge)
            NSColor.white.setFill(); edge.fill()
            let face = NSBezierPath(); l.forEach { face.append(outline($0, 56)) }
            (sticker == .yellowTilde ? warm : NSColor.white).setFill(); face.fill(); stroke(face, ink, 9)
        }
    case .page:
        rotated(8, around: c) {   // a calendar page
            let page = NSRect(x: c.x - 95, y: c.y - 105, width: 190, height: 210)
            let edge = rr(page.insetBy(dx: -20, dy: -20), 54)
            dropShadow(edge)
            NSColor.white.setFill(); edge.fill()
            clipped(rr(page, 34)) { rgb(0xF4373D).setFill(); NSRect(x: page.minX, y: page.maxY - 58, width: page.width, height: 58).fill() }
            stroke(rr(page, 34), ink, 9)
            text("22", rounded(110, .heavy), ink, at: NSPoint(x: page.midX, y: page.midY - 26))
        }
    case .tick:
        rotated(12, around: c) {   // a tick
            let r: CGFloat = 92
            let edge = oval(c, r + 20)
            dropShadow(edge)
            NSColor.white.setFill(); edge.fill()
            let dot = oval(c, r)
            rgb(0x3D3AD3).setFill(); dot.fill(); stroke(dot, ink, 9)
            let tick = NSBezierPath(); tick.move(to: NSPoint(x: c.x - 44, y: c.y + 2)); tick.line(to: NSPoint(x: c.x - 10, y: c.y - 32)); tick.line(to: NSPoint(x: c.x + 46, y: c.y + 34))
            stroke(tick, .white, 26)
        }
    case .notepad:
        rotated(-8, around: c) {   // a ruled pad
            let pad = NSRect(x: c.x - 82, y: c.y - 100, width: 164, height: 200)
            let edge = rr(pad.insetBy(dx: -20, dy: -20), 48)
            dropShadow(edge)
            NSColor.white.setFill(); edge.fill()
            clipped(rr(pad, 28)) {
                NSColor.white.setFill(); pad.fill()
                rgb(0x3D3AD3).setFill(); NSRect(x: pad.minX, y: pad.maxY - 44, width: pad.width, height: 44).fill()
            }
            for (i, length) in [0.7, 0.7, 0.42].enumerated() {   // lines of writing, the last one unfinished
                let y = pad.maxY - 84 - CGFloat(i) * 38
                let line = NSBezierPath(); line.move(to: NSPoint(x: pad.minX + 28, y: y)); line.line(to: NSPoint(x: pad.minX + 28 + pad.width * length, y: y))
                stroke(line, ink, 10)
            }
            stroke(rr(pad, 28), ink, 9)
            for i in 0..<3 {   // the binding's rings
                let x = pad.minX + 40 + CGFloat(i) * 42
                let ring = NSBezierPath(); ring.move(to: NSPoint(x: x, y: pad.maxY - 24)); ring.line(to: NSPoint(x: x, y: pad.maxY + 12))
                stroke(ring, ink, 11)
            }
        }
    case .name:
        rotated(-6, around: c) {   // the name, cut out
            let font = rounded(120, .black)
            text("lães", font, rgb(0x000000, 0.25), at: NSPoint(x: c.x, y: c.y - 8), outline: -46)
            text("lães", font, .white, at: c, outline: -46)
            text("lães", font, ink, at: c)
        }
    }
}

/// The icon on a 1024 canvas. `fullBleed` (iOS): no plate shape or shadow, the plate scaled to fill the square; iOS rounds it.
func draw(fullBleed: Bool, plate: Bool = true, design: Design = standard) {
    if fullBleed {
        let t = NSAffineTransform(); t.scale(by: S / P.width); t.translateX(by: -P.minX, yBy: -P.minY); t.concat()
    } else {
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow(); s.shadowColor = rgb(0x000000, 0.3); s.shadowBlurRadius = 26; s.shadowOffset = NSSize(width: 0, height: -12); s.set()
        NSColor.white.setFill(); rr(P, 185).fill()
        NSGraphicsContext.restoreGraphicsState()
        rr(P, 185).addClip()
    }
    if plate { drawPlate() }
    for corner in Corner.allCases { if let sticker = design[corner] { drawSticker(sticker, at: corner) } }
}

func render(fullBleed: Bool, plate: Bool = true, design: Design = standard) -> NSBitmapImageRep {
    let rep = newRep(Int(S))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(fullBleed: fullBleed, plate: plate, design: design)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func png(_ master: NSBitmapImageRep, _ pixels: Int) -> Data {
    let rep = newRep(pixels)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let img = NSImage(size: NSSize(width: S, height: S)); img.addRepresentation(master)
    img.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let mac = render(fullBleed: false)
let out = URL(fileURLWithPath: "Laes/Assets.xcassets/AppIcon.appiconset")
var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try png(mac, points * scale).write(to: out.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
let fm = FileManager.default
func write(_ data: Data, _ path: String) throws {
    let url = URL(fileURLWithPath: path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
let iconJSON = Data(#"{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#.utf8)
func imageJSON(_ file: String) -> Data { Data(#"{"images":[{"filename":"\#(file)","idiom":"universal"}],"info":{"author":"xcode","version":1}}"#.utf8) }
let catalogJSON = Data(#"{"info":{"author":"xcode","version":1}}"#.utf8)

// iPhone: the standard icon, then every other design as an alternate icon. Old designs' sets go first.
let iosCatalog = "LaesiOS/Assets.xcassets"
for old in try fm.contentsOfDirectory(atPath: iosCatalog) where old.hasPrefix("AppIcon-") { try fm.removeItem(atPath: "\(iosCatalog)/\(old)") }
let designs = allDesigns()
for design in designs {
    let dir = "\(iosCatalog)/\(iconName(design) ?? "AppIcon").appiconset"
    try write(png(render(fullBleed: true, design: design), 1024), "\(dir)/icon.png")
    try write(iconJSON, "\(dir)/Contents.json")
}
try write(catalogJSON, "\(iosCatalog)/Contents.json")

// The editor's layers: plates (full-bleed, and the Mac's with its shape and shadow), and each sticker cut to its bounds,
// placed around a corner's centre (it only moves between corners, so one picture serves both).
try write(png(render(fullBleed: true, design: [:]), 1024), "Laes/Stickers.xcassets/IconPlate.imageset/IconPlate.png")
try write(imageJSON("IconPlate.png"), "Laes/Stickers.xcassets/IconPlate.imageset/Contents.json")
try write(catalogJSON, "Laes/Stickers.xcassets/Contents.json")
try write(png(render(fullBleed: false, design: [:]), 1024), "Laes/Assets.xcassets/IconPlateMac.imageset/IconPlateMac.png")
try write(imageJSON("IconPlateMac.png"), "Laes/Assets.xcassets/IconPlateMac.imageset/Contents.json")
let f = { (v: CGFloat) in String(format: "%.4f", v) }
var pictures: [String] = []
for sticker in Sticker.allCases {
    let corner = sticker.corners[0]
    let rep = render(fullBleed: true, plate: false, design: [corner: sticker])
    var (x0, y0, x1, y1) = (Int(S), Int(S), 0, 0)   // the drawn pixels' bounds, rows from the top
    for y in 0..<Int(S) { for x in 0..<Int(S) where rep.colorAt(x: x, y: y)!.alphaComponent > 0.01 {
        (x0, y0, x1, y1) = (min(x0, x), min(y0, y), max(x1, x + 1), max(y1, y + 1))
    } }
    let crop = NSBitmapImageRep(cgImage: rep.cgImage!.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))!)
    let name = "Sticker-\(sticker.rawValue)"
    try write(crop.representation(using: .png, properties: [:])!, "Laes/Stickers.xcassets/\(name).imageset/\(name).png")
    try write(imageJSON("\(name).png"), "Laes/Stickers.xcassets/\(name).imageset/Contents.json")
    let (cx, cy) = (corner.centre.x, 1 - corner.centre.y)   // full bleed: the plate fills the icon
    pictures.append("        case .\(sticker.rawValue): CGRect(x: \(f(CGFloat(x0) / S - cx)), y: \(f(CGFloat(y0) / S - cy)), width: \(f(CGFloat(x1 - x0) / S)), height: \(f(CGFloat(y1 - y0) / S)))")
}
let centres = Corner.allCases.map { "        case .\($0.rawValue): CGPoint(x: \(f($0.centre.x)), y: \(f(1 - $0.centre.y)))" }
try write(Data("""
// Generated by Scripts/make-icon.swift; run it again after changing a sticker or a corner. Don't edit.
import CoreGraphics

extension Sticker {
    /// Its picture (Sticker-<name> in Stickers.xcassets) around the centre of its corner, in fractions of the icon's side, y down.
    var picture: CGRect {
        switch self {
\(pictures.joined(separator: "\n"))
        }
    }
}

extension Corner {
    /// Where a sticker's centre goes, in fractions of the icon's side from the top left.
    var centre: CGPoint {
        switch self {
\(centres.joined(separator: "\n"))
        }
    }
}

""".utf8), "Laes/Views/StickerFrames.swift")
print("wrote \(images.count) Mac icon sizes, \(designs.count) iPhone icons, \(Sticker.allCases.count) stickers")
