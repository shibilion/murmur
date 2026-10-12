// Draws Murmur's DMG background (1x 640x400 and 2x 1280x800) with gradient, arrow and hint text.
// Usage: swift scripts/make-dmg-background.swift   (run from the repo root)
// Layout in window points (AppKit origin is bottom-left; window is 640x400):
//   icon slots at (160,200) and (480,200); the arrow runs between them; hint text near the bottom.
import AppKit

let W: CGFloat = 640
let H: CGFloat = 400

func render(scale s: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(W) * s, pixelsHigh: Int(H) * s,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: W, height: H)  // 72 dpi @1x, 144 dpi @2x
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    // rep.size is in points, so the context already maps points to pixels; no manual scaling.

    NSGradient(colors: [
        NSColor(srgbRed: 0.49, green: 0.33, blue: 0.93, alpha: 1),  // violet (top)
        NSColor(srgbRed: 0.24, green: 0.20, blue: 0.62, alpha: 1),  // deep indigo (bottom)
    ])!.draw(from: NSPoint(x: W / 2, y: H), to: NSPoint(x: W / 2, y: 0), options: [])

    // Arrow between the icon slots (160,200) -> (480,200), leaving room for the 96pt icons.
    let y: CGFloat = 200
    let x0: CGFloat = 160 + 48 + 28
    let x1: CGFloat = 480 - 48 - 28
    let white = NSColor.white.withAlphaComponent(0.85)
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: x0, y: y))
    shaft.line(to: NSPoint(x: x1 - 10, y: y))
    white.setStroke()
    shaft.lineWidth = 4
    shaft.lineCapStyle = .round
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: x1, y: y))
    head.line(to: NSPoint(x: x1 - 18, y: y + 11))
    head.line(to: NSPoint(x: x1 - 18, y: y - 11))
    head.close()
    white.setFill()
    head.fill()

    // Hint text near the BOTTOM-LEFT (y ~ 40), one line, clear of the arrow and of the README
    // icon that Finder places at (320,330 from top), whose footprint is x 272-368.
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ]
    NSAttributedString(string: "First time? See \u{201C}First open \u{2014} read me\u{201D}", attributes: attrs).draw(at: NSPoint(x: 24, y: 30))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

do {
    try render(scale: 1).write(to: URL(fileURLWithPath: "Resources/dmg-background.png"))
    try render(scale: 2).write(to: URL(fileURLWithPath: "Resources/dmg-background@2x.png"))
    print("Wrote Resources/dmg-background.png (640x400) and dmg-background@2x.png (1280x800)")
} catch {
    fatalError("Failed to write background: \(error)")
}
