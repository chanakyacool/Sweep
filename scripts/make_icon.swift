// Renders the Sweep app icon and packages it as AppIcon.icns.
// Usage: swift scripts/make_icon.swift <output-directory>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let canvas: CGFloat = 1024

func render() -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // macOS icon grid: an 824pt rounded square centred on a 1024pt canvas.
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 1),
        NSColor(red: 0.10, green: 0.10, blue: 0.22, alpha: 1),
    ])!.draw(in: shape, angle: 90)

    let violet = NSColor(red: 0.545, green: 0.424, blue: 1.0, alpha: 1)
    let sky = NSColor(red: 0.22, green: 0.776, blue: 1.0, alpha: 1)
    let center = NSPoint(x: 512, y: 512)

    // Soft glow behind the orb.
    NSGradient(colors: [violet.withAlphaComponent(0.55), violet.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: 152, y: 152, width: 720, height: 720)), relativeCenterPosition: .zero)

    // The scan ring: a three-quarter arc, as in the app's scan orb.
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: 290, startAngle: 120, endAngle: 30, clockwise: false)
    ring.lineWidth = 46
    ring.lineCapStyle = .round
    sky.setStroke()
    ring.stroke()

    // The orb itself, with a highlight on its upper half.
    let orb = NSBezierPath(ovalIn: NSRect(x: center.x - 205, y: center.y - 205, width: 410, height: 410))
    NSGradient(colors: [sky, violet])!.draw(in: orb, angle: 135)
    NSGraphicsContext.saveGraphicsState()
    orb.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.38), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSRect(x: center.x - 205, y: center.y, width: 410, height: 205), angle: 270)
    NSGraphicsContext.restoreGraphicsState()

    // A four-point sparkle in the centre.
    func sparkle(at p: NSPoint, size s: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: p.x, y: p.y + s))
        path.curve(to: NSPoint(x: p.x + s, y: p.y), controlPoint1: NSPoint(x: p.x + s * 0.12, y: p.y + s * 0.12), controlPoint2: NSPoint(x: p.x + s * 0.12, y: p.y + s * 0.12))
        path.curve(to: NSPoint(x: p.x, y: p.y - s), controlPoint1: NSPoint(x: p.x + s * 0.12, y: p.y - s * 0.12), controlPoint2: NSPoint(x: p.x + s * 0.12, y: p.y - s * 0.12))
        path.curve(to: NSPoint(x: p.x - s, y: p.y), controlPoint1: NSPoint(x: p.x - s * 0.12, y: p.y - s * 0.12), controlPoint2: NSPoint(x: p.x - s * 0.12, y: p.y - s * 0.12))
        path.curve(to: NSPoint(x: p.x, y: p.y + s), controlPoint1: NSPoint(x: p.x - s * 0.12, y: p.y + s * 0.12), controlPoint2: NSPoint(x: p.x - s * 0.12, y: p.y + s * 0.12))
        NSColor.white.setFill()
        path.fill()
    }
    sparkle(at: NSPoint(x: center.x - 18, y: center.y - 12), size: 118)
    sparkle(at: NSPoint(x: center.x + 88, y: center.y + 86), size: 46)

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let master = "\(output)/AppIcon-1024.png"
try render().representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: master))

let iconset = NSTemporaryDirectory() + "Sweep.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try! process.run()
    process.waitUntilExit()
}

for size in [16, 32, 128, 256, 512] {
    run("/usr/bin/sips", ["-z", "\(size)", "\(size)", master, "--out", "\(iconset)/icon_\(size)x\(size).png"])
    run("/usr/bin/sips", ["-z", "\(size * 2)", "\(size * 2)", master, "--out", "\(iconset)/icon_\(size)x\(size)@2x.png"])
}
run("/usr/bin/iconutil", ["-c", "icns", iconset, "-o", "\(output)/AppIcon.icns"])
print("Wrote \(output)/AppIcon.icns")
