// Renders the Slimwarden app icon into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824pt body centered in 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.13, green: 0.47, blue: 1.00, alpha: 1).cgColor,
        NSColor(red: 0.33, green: 0.20, blue: 0.86, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    // Soft top highlight.
    let glow = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 900), endRadius: 520, options: [])
    ctx.restoreGState()

    // Shield.
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 812))
    shield.addCurve(to: CGPoint(x: 286, y: 724), control1: CGPoint(x: 440, y: 766), control2: CGPoint(x: 360, y: 736))
    shield.addLine(to: CGPoint(x: 286, y: 520))
    shield.addCurve(to: CGPoint(x: 512, y: 210), control1: CGPoint(x: 286, y: 370), control2: CGPoint(x: 390, y: 268))
    shield.addCurve(to: CGPoint(x: 738, y: 520), control1: CGPoint(x: 634, y: 268), control2: CGPoint(x: 738, y: 370))
    shield.addLine(to: CGPoint(x: 738, y: 724))
    shield.addCurve(to: CGPoint(x: 512, y: 812), control1: CGPoint(x: 664, y: 736), control2: CGPoint(x: 584, y: 766))
    shield.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shield)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Keyhole cut in the brand gradient.
    let keyhole = CGMutablePath()
    keyhole.addEllipse(in: CGRect(x: 512 - 70, y: 520, width: 140, height: 140))
    keyhole.move(to: CGPoint(x: 512 - 38, y: 548))
    keyhole.addLine(to: CGPoint(x: 512 - 58, y: 360))
    keyhole.addQuadCurve(to: CGPoint(x: 512 + 58, y: 360), control: CGPoint(x: 512, y: 340))
    keyhole.addLine(to: CGPoint(x: 512 + 38, y: 548))
    keyhole.closeSubpath()
    ctx.saveGState()
    ctx.addPath(keyhole)
    ctx.clip()
    ctx.drawLinearGradient(bg, start: CGPoint(x: 440, y: 660), end: CGPoint(x: 584, y: 340), options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: root.appendingPathComponent("build/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
