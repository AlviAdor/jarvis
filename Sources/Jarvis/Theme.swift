import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x3DD6F5
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#3DD6F5" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

enum AccentPresets {
    static let all = ["#3DD6F5", "#8B7CFF", "#3DF5A7", "#FFB23D", "#FF5C8A", "#E8EEF5"]
}

/// Liquid Glass on macOS 26, frosted material before that. For surfaces that float on their own.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
        }
    }
}

/// A clear pane drawn on top of the glass window: a faint fill and a hairline edge that catches the accent.
struct HUDPanel: ViewModifier {
    var radius: CGFloat = 18
    var accent: Color = .cyan
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(scheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035)))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [accent.opacity(0.45), .white.opacity(scheme == .dark ? 0.08 : 0.25), accent.opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.8)
            )
    }
}

extension View {
    func glassCard(_ radius: CGFloat = 20) -> some View { modifier(GlassCard(radius: radius)) }
    func hudPanel(_ radius: CGFloat = 18, accent: Color) -> some View { modifier(HUDPanel(radius: radius, accent: accent)) }
}

/// Turns the hosting window into a bezel-free glass pane: no title bar, no traffic lights,
/// transparent, and draggable from anywhere on its background.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        override func layout() {
            super.layout()
            configure()
        }

        private func configure() {
            guard let w = window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isMovableByWindowBackground = true
            w.hasShadow = true
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.isHidden = true
            }
        }
    }
}

/// Behind-window blur for systems before Liquid Glass.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// The window's own surface: glass, a faint circuit grid and an accent glow that warms up while Jarvis works.
struct GlassBackdrop: View {
    let accent: Color
    var busy = false
    var radius: CGFloat = 30
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(scheme == .dark ? .black.opacity(0.42) : .white.opacity(0.25)), in: shape)
            } else {
                VisualEffect(material: .hudWindow).clipShape(shape)
                shape.fill(scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.2))
            }
            CircuitGrid()
                .stroke(accent.opacity(scheme == .dark ? 0.07 : 0.06), lineWidth: 0.6)
                .clipShape(shape)
                .drawingGroup()
            RadialGradient(colors: [accent.opacity(busy ? 0.26 : 0.14), .clear], center: .init(x: 0.5, y: 0.26), startRadius: 10, endRadius: 360)
                .clipShape(shape)
                .animation(.easeInOut(duration: 0.8), value: busy)
        }
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.28), accent.opacity(0.3), .white.opacity(0.06)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        )
        .ignoresSafeArea()
    }
}

/// A sparse hexagonal grid. Static, so it is drawn once and cached.
struct CircuitGrid: Shape {
    var size: CGFloat = 26

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let h = size * sqrt(3) / 2
        var row = 0
        var y: CGFloat = 0
        while y < rect.height + h {
            var x: CGFloat = row.isMultiple(of: 2) ? 0 : size * 1.5
            while x < rect.width + size {
                let c = CGPoint(x: x, y: y)
                for i in 0..<6 {
                    let a1 = CGFloat(i) * .pi / 3, a2 = CGFloat(i + 1) * .pi / 3
                    p.move(to: CGPoint(x: c.x + size * cos(a1), y: c.y + size * sin(a1)))
                    p.addLine(to: CGPoint(x: c.x + size * cos(a2), y: c.y + size * sin(a2)))
                }
                x += size * 3
            }
            y += h
            row += 1
        }
        return p
    }
}

/// Thin corner brackets, like a targeting reticle, framing whatever they surround.
struct Reticle: Shape {
    var length: CGFloat = 16

    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = length
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

/// A tiny line chart of recent readings.
struct Sparkline: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: CGFloat(i) * step, y: rect.maxY - CGFloat(min(max(v, 0), 1)) * rect.height)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

/// Small uppercase label in the HUD's instrument style.
struct MicroLabel: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(color)
    }
}

/// Round glass button used in the window's own title area.
struct OrbButton: View {
    let icon: String
    var tint: Color = .primary
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint.opacity(hover ? 1 : 0.75))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCard(size / 2)
        .scaleEffect(hover ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
    }
}

struct PillButtonStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(tint.opacity(configuration.isPressed ? 0.35 : 0.22), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
