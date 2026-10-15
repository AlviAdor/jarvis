import AppKit

// Draws the Jarvis app icon at every size macOS needs: a particle globe with a tilted orbital ring,
// glowing in a dark glass squircle. Usage: swift scripts/make_icon.swift build/AppIcon.iconset
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let space = CGColorSpaceCreateDeviceRGB()
let cyan = (r: 0.26, g: 0.85, b: 0.97)

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

/// Apple's icon shape is a squircle (a superellipse), not a rounded rectangle.
func squircle(in r: CGRect, n: Double = 5) -> CGPath {
    let p = CGMutablePath()
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    for i in 0...360 {
        let t = Double(i) / 360 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = cy + b * CGFloat(copysign(pow(abs(s), 2 / n), s))
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

struct Dot { var x: Double; var y: Double; var z: Double; var ring: Bool }

/// Points on a globe (Fibonacci spiral) and on a tilted ring around it, projected with perspective.
func scene(globe count: Int, ring ringCount: Int) -> [Dot] {
    var dots: [Dot] = []
    let golden = Double.pi * (3 - sqrt(5))
    let yaw = 0.55, tilt = 0.42
    for i in 0..<count {
        let y = 1 - Double(i) / Double(count - 1) * 2
        let r = (1 - y * y).squareRoot()
        let t = golden * Double(i)
        var x = cos(t) * r, z = sin(t) * r, yy = y
        (x, z) = (cos(yaw) * x + sin(yaw) * z, -sin(yaw) * x + cos(yaw) * z)
        (yy, z) = (cos(tilt) * yy - sin(tilt) * z, sin(tilt) * yy + cos(tilt) * z)
        dots.append(Dot(x: x, y: yy, z: z, ring: false))
    }
    let rt = 0.36, rz = -0.38   // a Saturn-like tilt: a clear ellipse running across the globe
    for i in 0..<ringCount {
        let a = Double(i) / Double(ringCount) * 2 * .pi
        var x = cos(a) * 1.48, y = 0.0, z = sin(a) * 1.48
        (y, z) = (cos(rt) * y - sin(rt) * z, sin(rt) * y + cos(rt) * z)
        (x, y) = (cos(rz) * x - sin(rz) * y, sin(rz) * x + cos(rz) * y)
        dots.append(Dot(x: x, y: y, z: z, ring: true))
    }
    return dots.sorted { $0.z < $1.z }   // far side first
}

func draw(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    let small = px <= 64

    // The icon body on Apple's grid: 824 of 1024, centred, with room for the system shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = squircle(in: body)

    // Soft drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0, 0, 0, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(color(0.02, 0.04, 0.08, 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Deep-space background with a cool glow behind the globe.
    let bg = [color(0.06, 0.10, 0.19, 1), color(0.015, 0.025, 0.055, 1)] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: bg, locations: [0, 1])!,
                           start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    let c = CGPoint(x: body.midX, y: body.midY)
    let glow = [color(cyan.r, cyan.g, cyan.b, small ? 0.5 : 0.34), color(cyan.r, cyan.g, cyan.b, 0.06), color(cyan.r, cyan.g, cyan.b, 0)] as CFArray
    ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: glow, locations: [0, 0.45, 1])!,
                           startCenter: c, startRadius: 0, endCenter: c, endRadius: body.width * 0.5, options: [])

    // Particles: nearer ones larger and brighter; the ring carries the accent colour.
    let radius = Double(body.width) * 0.29
    let dots = scene(globe: small ? 160 : 950, ring: small ? 70 : 300)
    let cam = 3.4
    let unit = Double(s) / 1024
    for d in dots {
        let k = cam / (cam - d.z)
        let px = Double(c.x) + d.x * radius * k
        let py = Double(c.y) + d.y * radius * k
        let front = max(0, min(1, (d.z + 1.4) / 2.8))
        var size = (d.ring ? 2.4 + 2.2 * front : 1.5 + 3.0 * front) * unit * k
        if small { size = max(size * 2.2, 0.9) }
        let alpha = d.ring ? 0.3 + 0.7 * front : 0.14 + 0.86 * front
        let whiten = d.ring ? 0.08 + 0.25 * front : 0.5 + 0.5 * front
        let r = cyan.r + (1 - cyan.r) * whiten, g = cyan.g + (1 - cyan.g) * whiten, b = cyan.b + (1 - cyan.b) * whiten
        if !small, d.ring || front > 0.88 {
            ctx.setFillColor(color(r, g, b, alpha * (d.ring ? 0.16 : 0.1)))
            ctx.fillEllipse(in: CGRect(x: px - size * 1.6, y: py - size * 1.6, width: size * 3.2, height: size * 3.2))
        }
        ctx.setFillColor(color(r, g, b, alpha))
        ctx.fillEllipse(in: CGRect(x: px - size / 2, y: py - size / 2, width: size, height: size))
    }

    // A small bright nucleus at the heart of the globe.
    let core = [color(1, 1, 1, 0.9), color(cyan.r, cyan.g, cyan.b, 0.5), color(cyan.r, cyan.g, cyan.b, 0)] as CFArray
    ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: core, locations: [0, 0.35, 1])!,
                           startCenter: c, startRadius: 0, endCenter: c, endRadius: body.width * (small ? 0.12 : 0.085), options: [])

    // Glass: a soft highlight over the top and a thin bright rim.
    let sheen = [color(1, 1, 1, 0.13), color(1, 1, 1, 0)] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: sheen, locations: [0, 1])!,
                           start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.midY + body.height * 0.05), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim = [color(1, 1, 1, 0.42), color(cyan.r, cyan.g, cyan.b, 0.18), color(1, 1, 1, 0.06)] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: rim, locations: [0, 0.5, 1])!,
                           start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let d = draw(base * scale) { try? d.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
    }
}
