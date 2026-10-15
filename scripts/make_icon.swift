import AppKit

// Draws the Jarvis app icon at every size macOS needs.
// Usage: swift scripts/make_icon.swift build/AppIcon.iconset
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    let space = CGColorSpaceCreateDeviceRGB()

    // Standard macOS icon body: inset square with continuous-looking corners.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil))
    ctx.clip()

    let bg = [CGColor(red: 0.05, green: 0.08, blue: 0.15, alpha: 1), CGColor(red: 0.01, green: 0.02, blue: 0.04, alpha: 1)] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: bg, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: s), end: .zero, options: [])

    let c = CGPoint(x: s / 2, y: s / 2)
    let cyan = CGColor(red: 0.24, green: 0.84, blue: 0.96, alpha: 1)
    let glow = [cyan.copy(alpha: 0.55)!, cyan.copy(alpha: 0)!] as CFArray
    ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: glow, locations: [0, 1])!,
                           startCenter: c, startRadius: 0, endCenter: c, endRadius: body.width * 0.48, options: [])

    ctx.setLineCap(.round)
    for (i, r) in [0.18, 0.26, 0.34].enumerated() {
        let radius = body.width * CGFloat(r)
        ctx.setStrokeColor(cyan.copy(alpha: 0.95 - 0.2 * CGFloat(i))!)
        ctx.setLineWidth(max(1, s * (i == 0 ? 0.022 : 0.013)))
        let start = CGFloat(i) * 1.1 + 0.4
        for k in 0..<2 {
            let a0 = start + CGFloat(k) * .pi
            ctx.addArc(center: c, radius: radius, startAngle: a0, endAngle: a0 + 1.25 + 0.5 * CGFloat(i), clockwise: false)
            ctx.strokePath()
        }
    }

    let core = [CGColor(red: 1, green: 1, blue: 1, alpha: 1), cyan, cyan.copy(alpha: 0.3)!] as CFArray
    ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: core, locations: [0, 0.55, 1])!,
                           startCenter: c, startRadius: 0, endCenter: c, endRadius: body.width * 0.1, options: [])
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let d = draw(base * scale) { try? d.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }
}
