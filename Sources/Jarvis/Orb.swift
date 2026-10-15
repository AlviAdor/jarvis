import SwiftUI

struct OrbView: View {
    let phase: Phase
    let accent: Color
    let still: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: still ? 1 : 1.0 / 30)) { ctx in
            let t = still ? 0 : ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) / 2
                let energy: Double = phase == .idle ? 0.35 : (phase == .listening ? 1.0 : 0.75)
                let pulse = 1 + 0.06 * energy * sin(t * (phase == .idle ? 1.2 : 3.5))

                g.fill(Path(ellipseIn: CGRect(x: c.x - base * pulse, y: c.y - base * pulse, width: base * 2 * pulse, height: base * 2 * pulse)),
                       with: .radialGradient(Gradient(colors: [accent.opacity(0.55), accent.opacity(0.0)]),
                                             center: c, startRadius: 0, endRadius: base * pulse))

                for i in 0..<3 {
                    let r = base * (0.45 + 0.17 * Double(i)) * pulse
                    let a = t * (0.6 + 0.4 * Double(i)) * (i % 2 == 0 ? 1 : -1) * (0.5 + energy)
                    var ring = Path()
                    ring.addArc(center: c, radius: r, startAngle: .radians(a), endAngle: .radians(a + 4.2), clockwise: false)
                    g.stroke(ring, with: .color(accent.opacity(0.9 - 0.2 * Double(i))), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }

                let core = base * 0.22 * pulse
                g.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)),
                       with: .color(accent))
            }
        }
    }
}
