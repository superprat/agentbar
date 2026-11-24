// Draws AgentHUD's app icon and writes hud/AppIcon.icns.
//
//   swift hud/make-icon.swift            (run from the repo root)
//
// The icon mirrors the picker: a dark macOS-style rounded square holding three session rows,
// each with a status dot (needs you / working / done), the top row selected.

import AppKit

let canvas: CGFloat = 1024

func drawIcon(in ctx: CGContext, size: CGFloat) {
    let s = size / canvas
    ctx.scaleBy(x: s, y: s)

    // Body: the macOS icon grid (824 pt square, 100 pt margin), continuous corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).cgPath

    // Soft drop shadow, as on other Big Sur style icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.105, blue: 0.12, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: charcoal, slightly lighter at the top (light from above).
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 1).cgColor,
                                 NSColor(srgbRed: 0.09, green: 0.095, blue: 0.11, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Hairline inner edge so the dark body separates from dark backgrounds.
    ctx.saveGState()
    ctx.addPath(NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183).cgPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // Three session rows. Top one selected (accent fill), like the picker.
    let rowX: CGFloat = 196, rowW: CGFloat = 632, rowH: CGFloat = 150, gap: CGFloat = 46
    let stack = 3 * rowH + 2 * gap
    let firstY: CGFloat = body.minY + (body.height + stack) / 2 - rowH   // top row; stack centered
    let dots: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1),   // needs you (red)
        NSColor(srgbRed: 1.00, green: 0.72, blue: 0.20, alpha: 1),   // working (amber)
        NSColor(srgbRed: 0.20, green: 0.80, blue: 0.40, alpha: 1),   // done (green)
    ]
    for i in 0..<3 {
        let y = firstY - CGFloat(i) * (rowH + gap)
        let row = CGRect(x: rowX, y: y, width: rowW, height: rowH)
        let selected = i == 0
        ctx.addPath(NSBezierPath(roundedRect: row, xRadius: 40, yRadius: 40).cgPath)
        ctx.setFillColor(selected
            ? NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1).cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.fillPath()

        // Status dot, with a white ring on the selected row so red stays visible on blue.
        let d: CGFloat = 64
        let dot = CGRect(x: row.minX + 44, y: row.midY - d / 2, width: d, height: d)
        if selected {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: dot.insetBy(dx: -8, dy: -8))
        }
        ctx.setFillColor(dots[i].cgColor)
        ctx.fillEllipse(in: dot)

        // Text line placeholder.
        let line = CGRect(x: dot.maxX + 40, y: row.midY - 17, width: selected ? 330 : 280 - CGFloat(i) * 40, height: 34)
        ctx.addPath(NSBezierPath(roundedRect: line, xRadius: 17, yRadius: 17).cgPath)
        ctx.setFillColor(NSColor.white.withAlphaComponent(selected ? 0.95 : 0.55).cgColor)
        ctx.fillPath()
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    drawIcon(in: gc.cgContext, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hud")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: here.appendingPathComponent("AppIcon-1024.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(here.path)/AppIcon.icns" : "iconutil failed")
