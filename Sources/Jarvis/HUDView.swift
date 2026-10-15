import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JarvisCore

/// Shows the welcome tour until setup is done, then the HUD. Both sit on the same glass pane.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.needsOnboarding {
                OnboardingView()
                    .frame(maxWidth: 780)
                    .frame(minWidth: 700, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
            } else {
                HUDView().frame(minWidth: 620, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
            }
        }
        .background(GlassBackdrop(accent: model.accent, busy: model.busy))
        .background(WindowChrome())
        .preferredColorScheme(model.colorScheme)
        .tint(model.accent)
        .onAppear {
            model.openMainWindow = { openWindow(id: "hud") }
            fitWindow(force: model.needsOnboarding)
        }
        .onChange(of: model.needsOnboarding) { _, _ in fitWindow(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let w = note.object as? NSWindow, w.identifier?.rawValue.contains("hud") == true else { return }
            model.windowVisible = w.occlusionState.contains(.visible) && w.isVisible
        }
    }
}

extension RootView {
    /// Sizes the window for what it's showing: setup gets room for its pages, the main view its own shape.
    /// The main view keeps whatever size the user gave it unless it's too small; nothing exceeds the screen.
    func fitWindow(force: Bool) {
        DispatchQueue.main.async {
            guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("hud") == true }),
                  let screen = w.screen ?? NSScreen.main else { return }
            let setup = model.needsOnboarding
            let want = setup ? CGSize(width: 840, height: 760) : CGSize(width: 880, height: 720)
            let minimum = setup ? CGSize(width: 700, height: 600) : CGSize(width: 620, height: 560)
            let current = w.contentLayoutRect.size
            guard force || current.width < minimum.width || current.height < minimum.height else { return }
            let vis = screen.visibleFrame
            let size = CGSize(width: min(want.width, vis.width - 40), height: min(want.height, vis.height - 40))
            var frame = w.frameRect(forContentRect: CGRect(origin: .zero, size: size))
            frame.origin = CGPoint(x: vis.midX - frame.width / 2, y: vis.midY - frame.height / 2)
            w.setFrame(frame, display: true, animate: w.isVisible)
        }
    }
}

struct HUDView: View {
    @EnvironmentObject var model: AppModel
    @State private var showHistory = false
    @State private var dropping = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                TopBar(showHistory: $showHistory)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                Spacer(minLength: 6)
                SphereStage()
                Spacer(minLength: 6)
                VStack(spacing: 14) {
                    AnswerArea()
                    if !model.steps.isEmpty {
                        ActivityCard(steps: model.steps, accent: model.accent, running: model.busy)
                            .frame(maxWidth: 560)
                            .transition(.opacity)
                    }
                    if model.store.value.showTelemetry {
                        TelemetryStrip(telemetry: model.telemetry)
                            .frame(maxWidth: 560)
                    }
                    Composer()
                        .frame(maxWidth: 640)
                    if model.store.value.userDetails { DetailsView().frame(maxWidth: 640) }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.answer.isEmpty)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.steps.count)
            .animation(.easeOut(duration: 0.2), value: model.attachments.count)

            if showHistory {
                HStack {
                    Spacer()
                    HistoryPanel(open: $showHistory)
                        .frame(width: 340)
                        .padding(.top, 60)
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if let n = model.notice {
                HStack(spacing: 12) {
                    Text(n)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if let action = model.noticeAction {
                        Button(action) { model.runNoticeAction() }
                            .buttonStyle(.borderless)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(model.accent)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassCard(20)
                .onTapGesture { model.dismissNotice() }
                .help("Click to dismiss")
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(model.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(model.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(Label("Drop to attach", systemImage: "paperclip").font(.title3.weight(.medium)))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            Drops.load(providers) { urls, images in
                model.attach(urls)
                images.forEach { model.attachImage($0) }
            }
            return true
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .animation(.easeOut(duration: 0.25), value: showHistory)
        .animation(.easeOut(duration: 0.15), value: dropping)
    }
}

/// Turns dropped items into file URLs and image data.
enum Drops {
    static func load(_ providers: [NSItemProvider], done: @escaping @MainActor ([URL], [Data]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        var images: [Data] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.withLock { urls.append(url) } }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data { lock.withLock { images.append(data) } }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(urls, images) } }
    }
}

// MARK: Top bar

/// A small square control, like the rest of the instrument panel.
private struct SquareButton: View {
    let icon: String
    var active = false
    var tint: Color = .primary
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? tint : Color.primary.opacity(hover ? 0.95 : 0.7))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(active ? tint.opacity(0.18) : Color.primary.opacity(hover ? 0.08 : 0.04)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(active ? tint.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 0.8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var voice = AppModel.shared.voice
    @Binding var showHistory: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Circle().fill(model.accent).frame(width: 6, height: 6).shadow(color: model.accent, radius: 4)
                Text("JARVIS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                Rectangle().fill(model.accent.opacity(0.5)).frame(width: 18, height: 1)
                Text(status)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(model.accent.opacity(0.9))
                    .lineLimit(1)
                Rectangle().fill(model.accent.opacity(0.5)).frame(width: 18, height: 1)
            }
            HStack(spacing: 8) {
                Spacer()
                if !model.history.isEmpty {
                    SquareButton(icon: "clock.arrow.circlepath", active: showHistory, tint: model.accent, help: "Earlier answers") { showHistory.toggle() }
                }
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("Settings")
                SquareButton(icon: "xmark", help: "Close the window. Jarvis keeps listening.") { NSApp.keyWindow?.close() }
            }
        }
        .frame(height: 36)
    }

    private var status: String {
        if model.phase == .idle, !voice.running { return "MIC OFF · PRESS \(HotKey.label(model.store.value.hotkey))" }
        switch model.phase {
        case .idle: return model.store.value.wakeWordEnabled ? "READY · SAY \u{201C}\(model.store.value.wakeWord.uppercased())\u{201D}" : "READY"
        case .listening: return "LISTENING · GO AHEAD"
        case .thinking: return model.thinkOn ? "THINKING DEEPLY" : "THINKING"
        case .acting: return "ON YOUR SCREEN · ESC STOPS"
        case .speaking: return "SPEAKING"
        }
    }
}

// MARK: Sphere

private struct SphereStage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var voice = AppModel.shared.voice

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width * 0.62, g.size.height, 440)
            ZStack {
            RadialGradient(colors: [model.accent.opacity(0.22), model.accent.opacity(0.05), .clear], center: .center, startRadius: 4, endRadius: side * 0.42)
                .frame(width: side, height: side)
                .allowsHitTesting(false)
            OrbView(phase: model.phase, accent: model.accent, still: model.still, level: voice.level,
                    telemetry: model.store.value.showTelemetry ? ringValues : nil)
                .frame(width: side, height: side)
                .contentShape(Circle())
                .onTapGesture { model.pushToTalk() }
                .help("Tap, or press \(HotKey.label(model.store.value.hotkey)) anywhere, to talk")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 220)
    }

    private var ringValues: [Double]? {
        guard let s = model.telemetry.snapshot else { return nil }
        return [s.cpu, s.memoryFraction, Double(s.battery?.percent ?? 100) / 100]
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

/// The words: a greeting while idle, what you're saying while Jarvis listens, then the answer.
private struct AnswerArea: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var voice = AppModel.shared.voice

    var body: some View {
        VStack(spacing: 10) {
            if model.phase == .listening, !voice.partial.isEmpty {
                Text(voice.partial)
                    .font(.system(size: 24, weight: .light, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            } else if model.answer.isEmpty {
                if model.busy {
                    Text(model.question)
                        .font(.system(size: 22, weight: .light, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    ThinkingDots(accent: model.accent)
                } else {
                    Text(greeting)
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [.primary, model.accent], startPoint: .leading, endPoint: .trailing))
                }
            } else {
                if !model.question.isEmpty {
                    Text(model.question)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                ScrollView(showsIndicators: false) {
                    MarkdownAnswer(text: model.answerMarkdown.isEmpty ? model.answer : model.answerMarkdown, accent: model.accent)
                        .frame(maxWidth: 640)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(subtitle)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !model.answer.isEmpty, !model.busy {
                    Button { model.speakAgain() } label: { Image(systemName: "speaker.wave.2") }
                        .help("Read aloud")
                    Button { model.copyAnswer() } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy")
                    Button { model.regenerate() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Try again")
                    Button { model.editLast() } label: { Image(systemName: "pencil") }
                        .help("Edit your question")
                    ShareLink(item: model.answer) { Image(systemName: "square.and.arrow.up") }
                        .help("Share")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
    }

    private var greeting: String {
        let name = model.store.value.userName.split(separator: " ").first.map(String.init) ?? ""
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Hey" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : h < 22 ? "Good evening" : "Hey"
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }

    private var subtitle: String {
        if !model.answer.isEmpty, !model.answerSource.isEmpty { return model.answerSource }
        if model.busy { return model.phase == .acting ? "Working on your screen · Esc to stop" : "Working on it" }
        let brain = model.store.geminiKey.isEmpty ? "On-device" : (model.store.claudeKey.isEmpty ? "Gemini" : "Claude + Gemini")
        return "Say \u{201C}Jarvis\u{201D} or press \(HotKey.label(model.store.value.hotkey)) · \(brain) · remembers you"
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

/// Earlier answers, opened from the clock button.
private struct HistoryPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MicroLabel(text: "Earlier · \(model.history.count)")
                Spacer()
                Button("New conversation") { model.clearHistory(); open = false }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button { open = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.history.reversed()) { e in HistoryRow(exchange: e) }
                }
            }
        }
        .padding(14)
        .glassCard(18)
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
                .font(.system(size: 13, design: .serif))
                .textSelection(.enabled)
                .lineLimit(6)
        }
        .padding(.vertical, 2)
        .onHover { hover = $0 }
    }
}

/// Where you type, attach and choose tools, like the composer in modern AI apps.
private struct Composer: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments) { AttachmentChip(item: $0) }
                    }
                    .padding(.horizontal, 4)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Menu {
                        Button { model.pickFiles() } label: { Label("Attach files…", systemImage: "paperclip") }
                        Button { pasteFromClipboard() } label: { Label("Paste image or file", systemImage: "doc.on.clipboard") }
                        Button { model.attachScreenshot() } label: { Label("Add a screenshot of my screen", systemImage: "camera.viewfinder") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.07), in: Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Attach files, images, PDFs, audio or video")
                    TextField(placeholder, text: $model.typed, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14.5, design: .rounded))
                        .lineLimit(1...5)
                        .focused($focused)
                        .onSubmit { send() }
                    sendButton
                }
                HStack(spacing: 6) {
                    ToolPill(title: "Search", icon: "globe", on: $model.searchOn, help: "Look things up on the web, with sources")
                    ToolPill(title: "Think", icon: "lightbulb", on: $model.thinkOn, help: "Use the strongest model and think it through")
                    ToolPill(title: "Screen", icon: "cursorarrow.rays", on: $model.screenOn, help: "Let Jarvis see and operate your screen")
                    Spacer()
                    Menu {
                        Picker("Model", selection: binding(model, \.modelChoice)) {
                            Text("Auto").tag("auto")
                            Text("Lite · fastest").tag("lite")
                            Text("Flash · balanced").tag("flash")
                            Text("Pro · smartest").tag("pro")
                        }
                    } label: {
                        Text(model.store.value.modelChoice.capitalized)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Which model answers")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassCard(22)
        }
    }

    private var placeholder: String {
        model.attachments.isEmpty ? "Ask anything, or drop files here" : "Ask about \(model.attachments.count == 1 ? "this file" : "these files")…"
    }

    private var canSend: Bool { !model.typed.trimmingCharacters(in: .whitespaces).isEmpty || !model.attachments.isEmpty }

    @ViewBuilder private var sendButton: some View {
        if model.busy {
            Button { model.stopEverything() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop (Esc)")
        } else if canSend {
            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(model.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Send")
        } else {
            Button { model.pushToTalk() } label: {
                Image(systemName: model.phase == .listening ? "waveform" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(model.accent.opacity(model.phase == .listening ? 0.55 : 0.22), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Talk (\(HotKey.label(model.store.value.hotkey)))")
        }
    }

    private func send() {
        guard canSend else { return }
        model.submit(model.typed)
    }

    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            model.attach(urls)
        } else if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            model.attachImage(data)
        } else {
            model.flash("There's no image or file on the clipboard.")
        }
    }
}

private struct ToolPill: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let icon: String
    @Binding var on: Bool
    let help: String

    var body: some View {
        Button { on.toggle() } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(on ? model.accent : Color.secondary)
                .background(on ? model.accent.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
                .overlay(Capsule().stroke(on ? model.accent.opacity(0.6) : Color.clear, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct AttachmentChip: View {
    @EnvironmentObject var model: AppModel
    let item: Attachment

    var body: some View {
        HStack(spacing: 8) {
            if let t = item.thumbnail, let img = NSImage(data: t) {
                Image(nsImage: img).resizable().scaledToFill().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(model.accent)
                    .frame(width: 34, height: 34)
                    .background(model.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.caption.weight(.medium)).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                Text("\(item.kind.rawValue.uppercased()) · \(item.sizeLabel)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            Button { model.removeAttachment(item.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Remove")
        }
        .padding(6)
        .glassCard(12)
    }
}

/// An answer with light formatting: bold, italics, links and inline code, plus code blocks with a copy button.
/// Short plain answers are centred; anything with structure reads left to right.
struct MarkdownAnswer: View {
    let text: String
    let accent: Color

    private struct Segment: Identifiable {
        let id: Int
        let code: Bool
        let lang: String
        let body: String
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        let parts = text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                var lines = part.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                if !lines.isEmpty { lines.removeFirst() }
                out.append(Segment(id: i, code: true, lang: lang, body: lines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(Segment(id: i, code: false, lang: "", body: part.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return out
    }

    private var structured: Bool { text.contains("```") || text.components(separatedBy: "\n").count > 2 || text.count > 260 }

    var body: some View {
        VStack(alignment: structured ? .leading : .center, spacing: 10) {
            ForEach(segments) { seg in
                if seg.code {
                    CodeBlock(code: seg.body, lang: seg.lang, accent: accent)
                } else {
                    Text(Self.attributed(seg.body))
                        .font(.system(size: structured ? 16 : 23, weight: .light, design: .rounded))
                        .lineSpacing(structured ? 3 : 4)
                        .multilineTextAlignment(structured ? .leading : .center)
                        .textSelection(.enabled)
                        .tint(accent)
                        .frame(maxWidth: .infinity, alignment: structured ? .leading : .center)
                }
            }
        }
    }

    static func attributed(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

private struct CodeBlock: View {
    @EnvironmentObject var model: AppModel
    let code: String
    let lang: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button { model.copy(code) } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10.5)) }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(accent.opacity(0.25), lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
