import SwiftUI
import AppKit
import QuartzCore
import JarvisCore

/// The Jarvis orb, built from Core Animation layers. Its spin, pulse and breathing run in the
/// system render server, so the app does almost no work per frame even while the orb is visible.
final class OrbLayerView: NSView {
    private let levelLayer = CALayer()    // swells with your voice
    private let pulseLayer = CALayer()    // breathes
    private let spinLayer = CALayer()     // everything that rotates; its speed follows the phase
    private let halo = CAGradientLayer()
    private let tickRing = CALayer()
    private let ticksMajor = CAShapeLayer()
    private let ticksMinor = CAShapeLayer()
    private var arcs: [CAShapeLayer] = []
    private let core = CAGradientLayer()
    private var ringTracks: [CAShapeLayer] = []   // live CPU, memory and battery around the orb
    private var ringValues: [CAShapeLayer] = []

    private var accent: NSColor = .cyan
    private var phase: Phase?
    private var still = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        guard let root = layer else { return }
        root.addSublayer(levelLayer)
        levelLayer.addSublayer(pulseLayer)
        halo.type = .radial
        pulseLayer.addSublayer(halo)
        pulseLayer.addSublayer(spinLayer)
        spinLayer.addSublayer(tickRing)
        tickRing.addSublayer(ticksMinor)
        tickRing.addSublayer(ticksMajor)
        for i in 0..<3 {
            let a = CAShapeLayer()
            a.fillColor = nil
            a.lineCap = .round
            a.lineWidth = i == 0 ? 3 : 1.6
            arcs.append(a)
            spinLayer.addSublayer(a)
        }
        ticksMajor.fillColor = nil
        ticksMinor.fillColor = nil
        ticksMajor.lineWidth = 1
        ticksMinor.lineWidth = 1
        core.type = .radial
        pulseLayer.addSublayer(core)
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
        startAnimations()
    }

    private func spin(_ layer: CALayer, seconds: Double, clockwise: Bool) {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = clockwise ? -2 * Double.pi : 2 * Double.pi
        a.duration = seconds
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "spin")
    }

    private func startAnimations() {
        spin(tickRing, seconds: 42, clockwise: true)
        spin(arcs[0], seconds: 9, clockwise: false)
        spin(arcs[1], seconds: 13, clockwise: true)
        spin(arcs[2], seconds: 17, clockwise: false)
        let p = CABasicAnimation(keyPath: "transform.scale")
        p.fromValue = 0.965
        p.toValue = 1.035
        p.duration = 1.8
        p.autoreverses = true
        p.repeatCount = .infinity
        p.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        p.isRemovedOnCompletion = false
        pulseLayer.add(p, forKey: "pulse")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let c = CGPoint(x: b.midX, y: b.midY)
        let base = min(b.width, b.height) / 2
        for l in [levelLayer, pulseLayer, spinLayer, halo, tickRing, ticksMajor, ticksMinor] as [CALayer] { l.frame = b }
        arcs.forEach { $0.frame = b }

        let major = CGMutablePath(), minor = CGMutablePath()
        for i in 0..<60 {
            let a = Double(i) / 60 * 2 * .pi
            let r1 = base * 0.86, r2 = r1 - (i % 5 == 0 ? 7 : 3)
            let path = i % 5 == 0 ? major : minor
            path.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
            path.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
        }
        ticksMajor.path = major
        ticksMinor.path = minor

        for (i, arc) in arcs.enumerated() {
            let r = base * (0.42 + 0.14 * CGFloat(i))
            let sweep = 1.2 + 0.9 * CGFloat(i)
            let path = CGMutablePath()
            for k in 0..<2 {
                let start = CGFloat(k) * .pi + CGFloat(i) * 0.7
                path.move(to: CGPoint(x: c.x + cos(start) * r, y: c.y + sin(start) * r))
                path.addArc(center: c, radius: r, startAngle: start, endAngle: start + sweep, clockwise: false)
            }
            arc.path = path
        }

        // Three 110° arcs with gaps, starting at the top and running clockwise.
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

        let coreR = base * 0.22
        core.frame = CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 1, y: 1)
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        CATransaction.commit()
        applyColors()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let a = accent.usingColorSpace(.sRGB) ?? accent
        halo.colors = [a.withAlphaComponent(0.5).cgColor, a.withAlphaComponent(0.1).cgColor, NSColor.clear.cgColor]
        halo.locations = [0, 0.55, 1]
        ticksMajor.strokeColor = a.withAlphaComponent(0.55).cgColor
        ticksMinor.strokeColor = a.withAlphaComponent(0.22).cgColor
        for (i, arc) in arcs.enumerated() { arc.strokeColor = a.withAlphaComponent(0.9 - 0.22 * CGFloat(i)).cgColor }
        core.colors = [NSColor.white.withAlphaComponent(0.95).cgColor, a.cgColor, a.withAlphaComponent(0.35).cgColor]
        core.locations = [0, 0.55, 1]
        for (i, t) in ringTracks.enumerated() {
            t.strokeColor = a.withAlphaComponent(0.12).cgColor
            ringValues[i].strokeColor = (i == 2 ? NSColor.white.withAlphaComponent(0.85) : a.withAlphaComponent(i == 0 ? 0.95 : 0.7)).cgColor
        }
        CATransaction.commit()
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
            applyColors()
        }
        if phase != self.phase || still != self.still {
            self.phase = phase
            self.still = still
            let spinSpeed: Float, pulseSpeed: Float
            switch phase {
            case .idle: (spinSpeed, pulseSpeed) = (0.6, 1)
            case .listening: (spinSpeed, pulseSpeed) = (1.6, 2)
            case .thinking: (spinSpeed, pulseSpeed) = (2.2, 1.6)
            case .acting: (spinSpeed, pulseSpeed) = (2.6, 1.8)
            case .speaking: (spinSpeed, pulseSpeed) = (1.2, 4.5)
            }
            setSpeed(spinLayer, still ? 0 : spinSpeed)
            setSpeed(pulseLayer, still ? 0 : pulseSpeed)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        let s = 1 + min(level, 1) * 0.22
        levelLayer.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }
}

struct OrbView: NSViewRepresentable {
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
