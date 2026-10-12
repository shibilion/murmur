// Draws Murmur's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func drawIcon(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius, centred.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Soft drop shadow beneath the body.
    if px >= 64 {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.shadowBlurRadius = s * 0.025
        shadow.set()
    }
    NSColor.black.setFill()
    squircle.fill()
    NSShadow().set()

    // Indigo → violet gradient body.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.20, blue: 0.62, alpha: 1),  // deep indigo (bottom)
        NSColor(srgbRed: 0.49, green: 0.33, blue: 0.93, alpha: 1),  // violet (top)
    ])!
    gradient.draw(in: squircle, angle: 90)

    // Five rounded waveform bars, tallest in the middle.
    let heights: [CGFloat] = [0.26, 0.46, 0.66, 0.46, 0.26]
    let barW = body.width * 0.085
    let gap = body.width * 0.06
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    NSColor.white.setFill()
    for h in heights {
        let barH = body.height * h
        let bar = NSRect(x: x, y: body.midY - barH / 2, width: barW, height: barH)
        NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in sizes {
    try drawIcon(px: px).write(to: iconset.appendingPathComponent("\(name).png"))
}
try drawIcon(px: 1024).write(to: URL(fileURLWithPath: "build/AppIcon-preview.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns (preview: build/AppIcon-preview.png)")
