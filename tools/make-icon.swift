// Renders the app icon: macOS-style rounded tile, deep blue gradient, the
// app's externaldrive.badge.plus identity in white with a soft shadow.
// Usage: swift make-icon.swift <outdir>   (writes icon_<size>.png set)
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func drawIcon(_ px: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    defer { img.unlockFocus() }
    let s = px / 1024.0

    // macOS icon grid: tile is ~824pt of the 1024 canvas, corner radius ~185.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

    // Subtle drop shadow behind the tile.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.withAlphaComponent(0.30).setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Deep blue gradient tile.
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.16, blue: 0.45, alpha: 1),
    ])!
    grad.draw(in: path, angle: -90)

    // Faint inner highlight along the top edge.
    let hl = NSBezierPath(roundedRect: tile.insetBy(dx: 6 * s, dy: 6 * s),
                          xRadius: 179 * s, yRadius: 179 * s)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    hl.lineWidth = 8 * s
    hl.stroke()

    // The glyph: same SF Symbol the menu bar uses.
    let cfg = NSImage.SymbolConfiguration(pointSize: 430 * s, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "externaldrive.fill.badge.plus",
                            accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let symSize = symbol.size
        let scale = min((560 * s) / symSize.width, (560 * s) / symSize.height)
        let w = symSize.width * scale, h = symSize.height * scale
        let origin = NSPoint(x: tile.midX - w / 2, y: tile.midY - h / 2)

        NSGraphicsContext.current?.saveGraphicsState()
        let gShadow = NSShadow()
        gShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        gShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
        gShadow.shadowBlurRadius = 14 * s
        gShadow.set()

        // Tint the template symbol white.
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        tinted.draw(in: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                    from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    return img
}

for px in sizes {
    let img = drawIcon(CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { continue }
    rep.size = NSSize(width: px, height: px)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(px).png"))
}
print("icons written to \(outDir)")
