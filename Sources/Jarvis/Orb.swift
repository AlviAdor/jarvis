import SwiftUI
import AppKit
import QuartzCore
import JarvisCore

/// The Jarvis orb: a glowing nucleus with electrons on three tilted orbits and a fine particle cloud.
/// Every motion is a Core Animation animation running in the system's render server, so the app itself
/// does almost no work per frame. Activity speeds the atom up; your voice makes it swell.
final class OrbLayerView: NSView {
    private let levelLayer = CALayer()     // swells with your voice
    private let pulseLayer = CALayer()     // breathes
    private let atomLayer = CALayer()      // orbits and electrons; its speed follows the phase
    private let precess = CALayer()        // slowly turns the whole atom
    private let halo = CAGradientLayer()
    private let cloud = CAEmitterLayer()
    private let core = CAGradientLayer()
    private let coreGlow = CALayer()
    private let tickRing = CALayer()
    private let ticksMajor = CAShapeLayer()
    private let ticksMinor = CAShapeLayer()
    private var orbits: [CAShapeLayer] = []
    private var electrons: [CALayer] = []
    private var ringTracks: [CAShapeLayer] = []   // live CPU, memory and battery around the orb
    private var ringValues: [CAShapeLayer] = []

    private var accent: NSColor = .cyan
    private var phase: Phase?
    private var still = false
    private var builtFor: CGSize = .zero
    private var colorsReady = false

    private static let tilts: [CGFloat] = [0, .pi / 3, 2 * .pi / 3]
    private static let periods: [Double] = [2.6, 3.4, 4.3]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        guard let root = layer else { return }
        root.addSublayer(tickRing)
        tickRing.addSublayer(ticksMinor)
        tickRing.addSublayer(ticksMajor)
        for l in [ticksMajor, ticksMinor] { l.fillColor = nil; l.lineWidth = 1 }

        root.addSublayer(levelLayer)
        levelLayer.addSublayer(pulseLayer)
        halo.type = .radial
        pulseLayer.addSublayer(halo)
        pulseLayer.addSublayer(cloud)
        pulseLayer.addSublayer(atomLayer)
        atomLayer.addSublayer(precess)
        for i in 0..<3 {
            let o = CAShapeLayer()
            o.fillColor = nil
            o.lineWidth = i == 0 ? 1.3 : 1
            orbits.append(o)
            precess.addSublayer(o)
        }
        for _ in 0..<4 {
            let e = CALayer()
            e.shadowOpacity = 1
            e.shadowRadius = 5
            e.shadowOffset = .zero
            electrons.append(e)
            precess.addSublayer(e)
        }
        coreGlow.shadowOpacity = 1
        coreGlow.shadowOffset = .zero
        pulseLayer.addSublayer(coreGlow)
        core.type = .radial
        pulseLayer.addSublayer(core)

        let cell = CAEmitterCell()
        cell.name = "dot"
        cell.contents = Self.dotImage
        cell.birthRate = 1
        cell.lifetime = 2.2
        cell.lifetimeRange = 0.8
        cell.velocity = 9
        cell.velocityRange = 7
        cell.emissionRange = .pi * 2
        cell.scale = 0.09
        cell.scaleRange = 0.05
        cell.alphaSpeed = -0.42
        cloud.emitterCells = [cell]
        cloud.emitterShape = .circle
        cloud.emitterMode = .volume
        cloud.renderMode = .additive
        cloud.birthRate = 12

        for _ in 0..<3 {
            let track = CAShapeLayer(), value = CAShapeLayer()
            for l in [track, value] {
                l.fillColor = nil
                l.lineCap = .round
                l.lineWidth = 2.2
                l.isHidden = true
                root.addSublayer(l)
            }
            value.strokeEnd = 0
            ringTracks.append(track)
            ringValues.append(value)
        }

        spin(tickRing, seconds: 48, clockwise: true)
        spin(precess, seconds: 36, clockwise: false)
        let p = CABasicAnimation(keyPath: "transform.scale")
        p.fromValue = 0.97
        p.toValue = 1.03
        p.duration = 1.9
        p.autoreverses = true
        p.repeatCount = .infinity
        p.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        p.isRemovedOnCompletion = false
        pulseLayer.add(p, forKey: "pulse")
        let g = CABasicAnimation(keyPath: "shadowRadius")
        g.fromValue = 10
        g.toValue = 18
        g.duration = 1.9
        g.autoreverses = true
        g.repeatCount = .infinity
        g.isRemovedOnCompletion = false
        coreGlow.add(g, forKey: "glow")
    }

    /// A soft round particle, drawn once.
    private static let dotImage: CGImage? = {
        let size = 32
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return nil }
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
        return ctx.makeImage()
    }()

    private func spin(_ layer: CALayer, seconds: Double, clockwise: Bool) {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = clockwise ? -2 * Double.pi : 2 * Double.pi
        a.duration = seconds
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "spin")
    }

    /// An orbit: an ellipse around the centre, tilted by `angle`.
    private static func orbitPath(center c: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat) -> CGPath {
        var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &t)
    }

    override func layout() {
        super.layout()
        let b = bounds
        guard b.width > 4, b.size != builtFor else { return }
        builtFor = b.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = CGPoint(x: b.midX, y: b.midY)
        let base = min(b.width, b.height) / 2
        for l in [levelLayer, pulseLayer, atomLayer, precess, halo, tickRing, ticksMajor, ticksMinor, cloud] as [CALayer] { l.frame = b }

        let major = CGMutablePath(), minor = CGMutablePath()
        for i in 0..<60 {
            let a = Double(i) / 60 * 2 * .pi
            let r1 = base * 0.88, r2 = r1 - (i % 5 == 0 ? 6 : 2.5)
            let path = i % 5 == 0 ? major : minor
            path.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
            path.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
        }
        ticksMajor.path = major
        ticksMinor.path = minor

        // Orbits and the electrons travelling along them.
        let rx = base * 0.7, ry = base * 0.25
        for (i, o) in orbits.enumerated() {
            o.frame = b
            o.path = Self.orbitPath(center: c, rx: rx, ry: ry, angle: Self.tilts[i])
        }
        let dot = max(4, base * 0.055)
        for (i, e) in electrons.enumerated() {
            let orbit = i % 3
            e.bounds = CGRect(x: 0, y: 0, width: dot, height: dot)
            e.cornerRadius = dot / 2
            e.position = c
            let a = CAKeyframeAnimation(keyPath: "position")
            a.path = Self.orbitPath(center: c, rx: rx, ry: ry, angle: Self.tilts[orbit])
            a.duration = Self.periods[orbit]
            a.calculationMode = .paced
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            a.timeOffset = i >= 3 ? Self.periods[orbit] / 2 : Double(i) * 0.7   // the fourth rides opposite the first
            e.add(a, forKey: "orbit")
        }

        let coreR = base * 0.2
        core.frame = CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)
        core.cornerRadius = coreR
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 1, y: 1)
        coreGlow.frame = core.frame
        coreGlow.cornerRadius = coreR
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        cloud.emitterPosition = c
        cloud.emitterSize = CGSize(width: coreR * 2.6, height: coreR * 2.6)

        // Three 110° telemetry arcs with gaps, starting at the top and running clockwise.
        let ringR = base * 0.975
        for i in 0..<3 {
            let start = CGFloat.pi / 2 - CGFloat(i) * 2 * .pi / 3 - 0.09
            let end = start - (2 * .pi / 3 - 0.18)
            let path = CGMutablePath()
            path.addArc(center: c, radius: ringR, startAngle: start, endAngle: end, clockwise: true)
            ringTracks[i].frame = b
            ringValues[i].frame = b
            ringTracks[i].path = path
            ringValues[i].path = path
        }
        CATransaction.commit()
        applyColors(animated: false)
    }

    private func applyColors(animated: Bool) {
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(0.9) } else { CATransaction.setDisableActions(true) }
        let a = accent.usingColorSpace(.sRGB) ?? accent
        halo.colors = [a.withAlphaComponent(0.42).cgColor, a.withAlphaComponent(0.08).cgColor, NSColor.clear.cgColor]
        halo.locations = [0, 0.6, 1]
        ticksMajor.strokeColor = a.withAlphaComponent(0.5).cgColor
        ticksMinor.strokeColor = a.withAlphaComponent(0.18).cgColor
        for (i, o) in orbits.enumerated() { o.strokeColor = a.withAlphaComponent(i == 0 ? 0.45 : 0.28).cgColor }
        for e in electrons {
            e.backgroundColor = NSColor.white.cgColor
            e.shadowColor = a.cgColor
        }
        core.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.9).cgColor, a.cgColor, a.withAlphaComponent(0.25).cgColor]
        core.locations = [0, 0.25, 0.7, 1]
        coreGlow.backgroundColor = a.withAlphaComponent(0.6).cgColor
        coreGlow.shadowColor = a.cgColor
        cloud.setValue(a.cgColor, forKeyPath: "emitterCells.dot.color")
        for (i, t) in ringTracks.enumerated() {
            t.strokeColor = a.withAlphaComponent(0.12).cgColor
            ringValues[i].strokeColor = (i == 2 ? NSColor.white.withAlphaComponent(0.85) : a.withAlphaComponent(i == 0 ? 0.95 : 0.7)).cgColor
        }
        CATransaction.commit()
        colorsReady = true
    }

    /// Changes a layer's animation speed without making it jump.
    private func setSpeed(_ layer: CALayer, _ speed: Float) {
        guard layer.speed != speed else { return }
        let now = CACurrentMediaTime()
        let local = layer.convertTime(now, from: nil)
        layer.beginTime = now
        layer.timeOffset = local
        layer.speed = speed
    }

    /// Values 0...1 for CPU, memory and battery; nil hides the ring.
    func setTelemetry(_ values: [Double]?) {
        let show = values != nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.7)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for i in 0..<3 {
            ringTracks[i].isHidden = !show
            ringValues[i].isHidden = !show
            if let v = values, i < v.count { ringValues[i].strokeEnd = CGFloat(min(max(v[i], 0.002), 1)) }
        }
        CATransaction.commit()
    }

    func update(phase: Phase, accent: NSColor, still: Bool, level: CGFloat) {
        if accent != self.accent {
            self.accent = accent
            applyColors(animated: colorsReady)
        }
        if phase != self.phase || still != self.still {
            self.phase = phase
            self.still = still
            let speed: Float, pulse: Float, particles: Float
            switch phase {
            case .idle: (speed, pulse, particles) = (0.55, 1, 10)
            case .listening: (speed, pulse, particles) = (1.4, 2, 28)
            case .thinking: (speed, pulse, particles) = (2.2, 1.6, 42)
            case .acting: (speed, pulse, particles) = (2.8, 1.8, 55)
            case .speaking: (speed, pulse, particles) = (1.2, 4, 30)
            }
            setSpeed(atomLayer, still ? 0 : speed)
            setSpeed(pulseLayer, still ? 0 : pulse)
            setSpeed(tickRing, still ? 0 : 1)
            cloud.birthRate = still ? 0 : particles
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        let s = 1 + min(level, 1) * 0.22
        levelLayer.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }
}

/// Jarvis's orb in the style chosen in Settings: the particle sphere or the nucleus.
struct OrbView: View {
    let phase: Phase
    let accent: Color
    let still: Bool
    var level: Float = 0
    var telemetry: [Double]? = nil
    /// How heavy the work is, 0 to 1; nil follows Jarvis's own workload.
    var intensity: Double? = nil
    @ObservedObject private var store = AppModel.shared.store
    @ObservedObject private var app = AppModel.shared

    var body: some View {
        if store.value.orbStyle == "nucleus" {
            NucleusView(phase: phase, accent: accent, still: still, level: level, telemetry: telemetry)
        } else {
            ParticleSphereView(phase: phase, accent: accent, still: still, level: level, intensity: intensity ?? app.intensity)
        }
    }
}

struct NucleusView: NSViewRepresentable {
    let phase: Phase
    let accent: Color
    let still: Bool
    var level: Float = 0
    var telemetry: [Double]? = nil

    func makeNSView(context: Context) -> OrbLayerView { OrbLayerView(frame: .zero) }

    func updateNSView(_ view: OrbLayerView, context: Context) {
        view.update(phase: phase, accent: NSColor(accent), still: still, level: CGFloat(level))
        view.setTelemetry(telemetry)
    }
}

/// Orb wired to the microphone level.
struct LiveOrb: View {
    @ObservedObject var voice: VoiceEngine
    let phase: Phase
    let accent: Color
    let still: Bool
    var telemetry: [Double]? = nil

    var body: some View {
        OrbView(phase: phase, accent: accent, still: still, level: voice.level, telemetry: telemetry)
            .accessibilityLabel("Jarvis")
    }
}
