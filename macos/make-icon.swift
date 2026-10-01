// Renders AppIcon.icns: three usage bars on a dark rounded square.
// Usage: swift macos/make-icon.swift <output.icns>
import AppKit

let output = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)

    // macOS icon grid: the tile is ~80% of the canvas.
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: color(0x2A2826), ending: color(0x141312))!.draw(in: tilePath, angle: -90)

    let bars: [(CGFloat, UInt32)] = [(0.92, 0x22B77A), (0.55, 0xD9A13B), (0.22, 0xE0533F)]
    let barWidth = s * 0.12
    let gap = s * 0.07
    let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
    let baseX = tile.midX - totalWidth / 2
    let baseY = tile.minY + s * 0.17
    let maxHeight = s * 0.46
    for (index, (fraction, hex)) in bars.enumerated() {
        let x = baseX + CGFloat(index) * (barWidth + gap)
        let radius = barWidth / 2
        color(0x3A3836).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barWidth, height: maxHeight), xRadius: radius, yRadius: radius).fill()
        color(hex).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barWidth, height: max(barWidth, maxHeight * fraction)), xRadius: radius, yRadius: radius).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try! iconutil.run()
iconutil.waitUntilExit()
