import SwiftUI
import AppKit
import JarvisCore

/// Shows the welcome tour until setup is done, then the HUD. Both sit on the same glass pane.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.needsOnboarding {
                OnboardingView().frame(width: 780, height: 640)
            } else {
                HUDView().frame(minWidth: 560, idealWidth: 600, minHeight: 720, idealHeight: 800)
            }
        }
        .background(GlassBackdrop(accent: model.accent, busy: model.busy))
        .background(WindowChrome())
        .preferredColorScheme(model.colorScheme)
        .tint(model.accent)
        .onAppear { model.openMainWindow = { openWindow(id: "hud") } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let w = note.object as? NSWindow, w.identifier?.rawValue.contains("hud") == true else { return }
            model.windowVisible = w.occlusionState.contains(.visible) && w.isVisible
        }
    }
}

struct HUDView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 12) {
                TitleBar()
                OrbStage(telemetry: model.telemetry)
                StatusLine(voice: model.voice, phase: model.phase, accent: model.accent, hotkey: model.store.value.hotkey)
                if model.store.value.showTelemetry {
                    TelemetryStrip(telemetry: model.telemetry)
                }
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        if !model.answer.isEmpty || model.busy {
                            AnswerCard()
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else if model.steps.isEmpty {
                            Suggestions()
                                .transition(.opacity)
                        }
                        if !model.steps.isEmpty {
                            ActivityCard(steps: model.steps, accent: model.accent, running: model.busy)
                                .transition(.opacity)
                        }
                        if model.history.count > 1 {
                            HistorySection()
                        }
                    }
                    .padding(.vertical, 2)
                }
                InputBar()
                if model.store.value.userDetails { DetailsView() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.answer.isEmpty)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.steps.count)

            if let n = model.notice {
                Text(n)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassCard(20)
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
    }
}

// MARK: Title bar

private struct TitleBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            OrbButton(icon: "xmark", size: 22) { NSApp.keyWindow?.close() }
                .help("Close the window. Jarvis keeps listening.")
            OrbButton(icon: "minus", size: 22) { NSApp.keyWindow?.miniaturize(nil) }
                .help("Minimise")
            Spacer(minLength: 8)
            VStack(spacing: 1) {
                Text("J·A·R·V·I·S")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(model.accent)
                    .shadow(color: model.accent.opacity(0.6), radius: 6)
                MicroLabel(text: statusText, color: model.voice.running ? .green.opacity(0.85) : .secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Picker("Model", selection: Binding(get: { model.store.value.modelChoice }, set: { model.store.value.modelChoice = $0 })) {
                    Text("Auto").tag("auto")
                    Text("Lite").tag("lite")
                    Text("Flash").tag("flash")
                    Text("Pro").tag("pro")
                }
            } label: {
                Label(model.store.value.modelChoice.capitalized, systemImage: "cpu")
                    .font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassCard(12)
            .help("Which Gemini model answers. Auto picks the cheapest one that fits.")
            UsageChip(usage: model.usage)
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassCard(11)
            .help("Settings")
        }
        .frame(height: 30)
    }

    private var statusText: String {
        if !model.voice.running { return "mic off" }
        if !model.store.geminiKey.isEmpty { return "online · gemini" + (model.store.claudeKey.isEmpty ? "" : " + claude") }
        return "online · on-device"
    }
}

// MARK: Orb

private struct OrbStage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        let ring = ringValues
        ZStack {
            Reticle(length: 18)
                .stroke(model.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(width: 262, height: 236)
            LiveOrb(voice: model.voice, phase: model.phase, accent: model.accent, still: model.still, telemetry: ring)
                .frame(width: 212, height: 212)
                .contentShape(Circle())
                .onTapGesture { model.pushToTalk() }
                .help("Tap, or press \(HotKey.label(model.store.value.hotkey)) anywhere, to talk")
            if let s = telemetry.snapshot, model.store.value.showTelemetry {
                ringLabel("CPU \(Int((s.cpu * 100).rounded()))%", angle: 30)
                ringLabel("MEM \(Int((s.memoryFraction * 100).rounded()))%", angle: -90)
                ringLabel(s.battery.map { "BAT \($0.percent)%" + ($0.charging ? " ⚡︎" : "") } ?? "AC", angle: 150)
            }
        }
        .frame(height: 240)
    }

    private var ringValues: [Double]? {
        guard model.store.value.showTelemetry, let s = telemetry.snapshot else { return nil }
        return [s.cpu, s.memoryFraction, Double(s.battery?.percent ?? 100) / 100]
    }

    private func ringLabel(_ text: String, angle: Double) -> some View {
        let r = 124.0
        let a = angle * .pi / 180
        return MicroLabel(text: text, color: model.accent.opacity(0.9))
            .fixedSize()
            .offset(x: cos(a) * r + (cos(a) > 0.2 ? 22 : cos(a) < -0.2 ? -22 : 0), y: -sin(a) * r)
    }
}

struct StatusLine: View {
    @ObservedObject var voice: VoiceEngine
    let phase: Phase
    let accent: Color
    let hotkey: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: color, radius: 4)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            Waveform(level: phase == .listening ? voice.level : 0, accent: accent)
                .opacity(phase == .listening ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.2), value: phase)
    }

    private var color: Color {
        switch phase {
        case .idle: return voice.running ? .green : .gray
        case .listening: return accent
        case .thinking: return .yellow
        case .acting: return .orange
        case .speaking: return accent
        }
    }

    private var text: String {
        switch phase {
        case .idle:
            if !voice.running { return "Microphone off" }
            return hotkey == "off" ? "Say \u{201C}Jarvis\u{201D}" : "Say \u{201C}Jarvis\u{201D} or press \(HotKey.label(hotkey))"
        case .listening: return voice.partial.isEmpty ? "Listening…" : voice.partial
        case .thinking: return "Thinking…"
        case .acting: return "Working on your screen. Press Esc to stop."
        case .speaking: return "Speaking"
        }
    }
}

/// Bars that dance with your voice while Jarvis listens. Drawn in one pass at a fixed size,
/// so a new mic level never makes the window lay itself out again.
private struct Waveform: View {
    let level: Float
    let accent: Color

    var body: some View {
        Canvas { g, size in
            let bars = 24
            let w: CGFloat = 3, gap: CGFloat = 3
            let total = CGFloat(bars) * (w + gap) - gap
            var x = (size.width - total) / 2
            for i in 0..<bars {
                let env = 0.35 + 0.65 * abs(sin(Double(i) * 0.9 + Double(level) * 23))
                let centre = 1 - abs(Double(i) - 11.5) / 13
                let h = 3 + CGFloat(Double(level) * 26 * env * centre)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                g.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(accent.opacity(0.85)))
                x += w + gap
            }
        }
        .frame(width: 150, height: 30)
    }
}

// MARK: Telemetry

private struct TelemetryStrip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        if let s = telemetry.snapshot {
            HStack(spacing: 8) {
                Gauge(title: "CPU", value: "\(Int((s.cpu * 100).rounded()))%", sub: s.thermal == "nominal" ? "cool" : s.thermal,
                      series: telemetry.cpu, fraction: s.cpu, ask: "How is my CPU doing and what's using it?")
                Gauge(title: "Memory", value: "\(Int((s.memoryFraction * 100).rounded()))%", sub: s.pressure == "normal" ? SystemMonitor.bytes(Int64(s.memoryUsed)) : s.pressure,
                      series: telemetry.memory, fraction: s.memoryFraction, ask: "What's using my memory?")
                Gauge(title: "Storage", value: SystemMonitor.bytes(s.diskFree), sub: "free",
                      series: nil, fraction: s.diskUsedFraction, ask: "What's taking up my disk space and what can I safely free?")
                if let b = s.battery {
                    Gauge(title: "Power", value: "\(b.percent)%", sub: b.charging ? "charging" : (b.onAC ? "on power" : "battery"),
                          series: nil, fraction: Double(b.percent) / 100, ask: "How is my battery's health?")
                } else {
                    Gauge(title: "Network", value: s.online ? "Online" : "Offline", sub: s.wifiOn == true ? "Wi-Fi" : "wired",
                          series: nil, fraction: s.online ? 1 : 0, ask: "How is my network connection?")
                }
            }
        }
    }
}

private struct Gauge: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let value: String
    let sub: String
    let series: [Double]?
    let fraction: Double
    let ask: String
    @State private var hover = false

    var body: some View {
        Button { model.submit(ask) } label: {
            VStack(alignment: .leading, spacing: 4) {
                MicroLabel(text: title)
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                ZStack(alignment: .bottomLeading) {
                    if let series, series.count > 1 {
                        Sparkline(values: series)
                            .stroke(model.accent, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                    } else {
                        GeometryReader { g in
                            Capsule().fill(model.accent.opacity(0.15))
                            Capsule().fill(model.accent).frame(width: g.size.width * CGFloat(min(max(fraction, 0.02), 1)))
                        }
                        .frame(height: 3)
                    }
                }
                .frame(height: 14)
                Text(sub)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hudPanel(14, accent: model.accent)
            .scaleEffect(hover ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(ask)
    }
}

// MARK: Answer

private struct AnswerCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.question.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MicroLabel(text: "You")
                    Text(model.question)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            if model.answer.isEmpty {
                ThinkingDots(accent: model.accent)
            } else {
                Text(model.answer)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if !model.answerSource.isEmpty {
                        MicroLabel(text: model.answerSource, color: Color.secondary.opacity(0.8))
                    }
                    Spacer()
                    Button { model.speakAgain() } label: { Image(systemName: "speaker.wave.2.fill") }
                        .help("Say it again")
                    Button { model.copyAnswer() } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .help("Copy the answer")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel(18, accent: model.accent)
    }
}

private struct ThinkingDots: View {
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
        }
        .frame(height: 20)
    }
}

// MARK: Activity

struct ActivityCard: View {
    let steps: [Step]
    let accent: Color
    let running: Bool
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: running ? "bolt.horizontal.circle.fill" : "checklist")
                        .foregroundStyle(accent)
                    MicroLabel(text: running ? "Working · step \(steps.count)" : "Done in \(steps.count) step\(steps.count == 1 ? "" : "s")", color: .primary.opacity(0.8))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        StepRow(step: step, accent: accent, last: i == steps.count - 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .hudPanel(16, accent: accent)
        .onChange(of: running) { _, now in
            if !now { withAnimation(.easeOut(duration: 0.3)) { expanded = steps.count <= 3 } }
            if now { expanded = true }
        }
    }
}

/// One step on a timeline, with the command or query it ran, like a terminal line.
private struct StepRow: View {
    let step: Step
    let accent: Color
    let last: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(tint.opacity(0.16)).frame(width: 22, height: 22)
                    if step.state == .running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: step.state == .failed ? "exclamationmark" : (step.icon ?? "checkmark"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(tint)
                    }
                }
                if !last {
                    Rectangle().fill(accent.opacity(0.25)).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                if let d = step.detail, !d.isEmpty {
                    Text(d)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(.bottom, last ? 0 : 10)
        }
    }

    private var tint: Color {
        switch step.state {
        case .running: return accent
        case .done: return .green
        case .failed: return .red
        }
    }
}

// MARK: History

private struct HistorySection: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                        MicroLabel(text: "Earlier · \(model.history.count - 1)")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if open {
                    Button("Clear") { model.clearHistory() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if open {
                ForEach(model.history.dropLast().reversed()) { e in
                    HistoryRow(exchange: e)
                }
            }
        }
        .padding(12)
        .hudPanel(14, accent: model.accent)
    }
}

private struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    let exchange: Exchange
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(exchange.question).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(exchange.at, style: .time).font(.caption2).foregroundStyle(.tertiary)
                Button { model.copy(exchange.answer) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .opacity(hover ? 1 : 0.4)
                    .help("Copy")
            }
            Text(exchange.answer)
                .font(.system(size: 13, design: .rounded))
                .textSelection(.enabled)
                .lineLimit(6)
        }
        .padding(.vertical, 4)
        .onHover { hover = $0 }
    }
}

// MARK: Suggestions and input

private struct Suggestions: View {
    @EnvironmentObject var model: AppModel
    private let items: [(String, String)] = [
        ("gauge.with.dots.needle.67percent", "How's my Mac doing?"),
        ("internaldrive", "Free up some disk space"),
        ("calendar", "What's on my calendar today?"),
        ("folder.badge.gearshape", "Organise my Downloads folder"),
        ("rectangle.on.rectangle", "What's on my screen?"),
        ("cloud.sun", "What's the weather today?"),
        ("envelope", "Summarise my unread mail"),
        ("sparkles", "What can you do?"),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(items, id: \.1) { icon, text in
                SuggestionButton(icon: icon, text: text)
            }
        }
    }
}

private struct SuggestionButton: View {
    @EnvironmentObject var model: AppModel
    let icon: String
    let text: String
    @State private var hover = false

    var body: some View {
        Button { model.submit(text) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(model.accent).frame(width: 18)
                Text(text).font(.callout).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .hudPanel(13, accent: hover ? model.accent : model.accent.opacity(0.4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct InputBar: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(model.accent)
                .padding(.leading, 8)
            TextField("Ask Jarvis anything, or tell it what to do…", text: $model.typed)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .rounded))
                .focused($focused)
                .onSubmit { model.submit(model.typed) }
            Button { model.pushToTalk() } label: {
                Image(systemName: model.phase == .listening ? "waveform" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(model.accent.opacity(model.phase == .listening ? 0.55 : 0.25), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Talk")
            Button { model.stopEverything() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.red.opacity(model.busy ? 0.4 : 0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop everything (Esc)")
        }
        .padding(7)
        .glassCard(25)
    }
}

private struct DetailsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        DisclosureGroup("Details") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
        }
        .font(.caption)
    }
}

private struct UsageChip: View {
    @ObservedObject var usage: UsageTracker

    var body: some View {
        Text("\(usage.requests) today")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .glassCard(12)
            .help("Cloud requests used today (\(usage.tokens / 1000)k tokens). Answers from the on-device model don't count.")
    }
}
