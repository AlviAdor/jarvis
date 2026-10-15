import SwiftUI
import JarvisCore

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

struct HUDView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("J.A.R.V.I.S")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(model.accent.opacity(0.9))
                Spacer()
                ModelMenu()
                CostChip()
            }

            OrbView(phase: model.phase, accent: model.accent, still: model.store.value.reduceMotion)
                .frame(height: 220)
                .onTapGesture { model.toggleListening() }

            StatusLine(voice: model.voice, phase: model.phase)

            FeedView()

            HStack(spacing: 10) {
                TextField("Type, or press the mic and speak", text: $model.typed)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit { model.submit(model.typed) }
                Button {
                    model.toggleListening()
                } label: {
                    Image(systemName: model.phase == .listening ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                        .frame(width: 40, height: 40)
                        .background(model.accent.opacity(model.phase == .listening ? 0.5 : 0.2), in: Circle())
                }
                .buttonStyle(.plain)
                Button {
                    model.stopEverything()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14))
                        .frame(width: 40, height: 40)
                        .background(.red.opacity(0.25), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop everything (Esc)")
            }
        }
        .padding(20)
        .background(
            ZStack {
                Color(red: 0.03, green: 0.04, blue: 0.07)
                RadialGradient(colors: [model.accent.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 420)
            }.ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
    }
}

private struct StatusLine: View {
    @ObservedObject var voice: VoiceInput
    let phase: Phase

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var text: String {
        switch phase {
        case .idle: return "STANDING BY"
        case .listening: return voice.partial.isEmpty ? "LISTENING" : voice.partial
        case .thinking: return "THINKING"
        case .acting: return "WORKING ON YOUR SCREEN · ESC TO STOP"
        }
    }
}

private struct FeedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.feed.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("You:") ? Color.white : model.accent.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(12)
            }
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: model.feed.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }
}

private struct ModelMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.store.value
        Menu {
            Button("Auto") { model.store.value.modelChoice = "auto" }
            Divider()
            ForEach(Catalog.all(s)) { m in
                Button(m.name) { model.store.value.modelChoice = m.id }
            }
        } label: {
            let name = Catalog.spec(id: s.modelChoice, s)?.name ?? "Auto"
            Text(name.uppercased())
                .font(.system(size: 11, design: .monospaced))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct CostChip: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        CostChipInner(cost: model.cost, budget: model.store.value.monthlyBudgetUSD)
    }
}

private struct CostChipInner: View {
    @ObservedObject var cost: CostTracker
    let budget: Double
    var body: some View {
        Text(String(format: "$%.2f / $%.0f", cost.month, budget))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}
