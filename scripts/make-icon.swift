// Draws the app icon (blue squircle, white viewfinder corners framing a minimalist camera)
// and writes Resources/AppIcon.icns via iconutil.
//
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Squircle body with a vertical blue gradient, inset like Apple's icon grid.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.33, green: 0.62, blue: 1.00, alpha: 1),
               ending: NSColor(calibratedRed: 0.13, green: 0.30, blue: 0.78, alpha: 1))!
        .draw(in: bodyPath, angle: -90)

    // Viewfinder corners.
    NSColor.white.setStroke()
    let corners = NSBezierPath()
    corners.lineWidth = 56 * s
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    let inset: CGFloat = 230 * s, arm: CGFloat = 150 * s
    let lo = inset, hi = 1024 * s - inset
    for (x, y, dx, dy) in [(lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0), (lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0)] {
        corners.move(to: NSPoint(x: x + dx * arm, y: y))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x, y: y + dy * arm))
    }
    corners.stroke()

    // A minimalist camera: rounded body with a viewfinder hump, the lens punched out.
    let lens = NSRect(x: 432 * s, y: 417 * s, width: 160 * s, height: 160 * s)
    NSGraphicsContext.saveGraphicsState()
    let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size))
    clip.append(NSBezierPath(ovalIn: lens))
    clip.windingRule = .evenOdd
    clip.addClip()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 322 * s, y: 362 * s, width: 380 * s, height: 270 * s),
                 xRadius: 56 * s, yRadius: 56 * s).fill()
    NSBezierPath(roundedRect: NSRect(x: 432 * s, y: 590 * s, width: 160 * s, height: 82 * s),
                 xRadius: 24 * s, yRadius: 24 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    // The lens ring inside the hole.
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 470 * s, y: 455 * s, width: 84 * s, height: 84 * s)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: px).write(to: iconset.appendingPathComponent(name))
    }
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
