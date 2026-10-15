import SwiftUI
import AppKit
import Combine
import JarvisCore

/// The floating bar. Opened with the shortcut it takes typing and voice; while Jarvis works on its own
/// it shows what's happening and lets clicks pass through.
private struct QuickView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        // Nothing to draw or update while the bar is hidden.
        if model.overlayVisible || model.quickActive { content } else { Color.clear.frame(width: 1, height: 1) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                LiveOrb(voice: model.voice, phase: model.phase, accent: model.accent, still: model.store.value.reduceMotion)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    MicroLabel(text: label, color: model.accent)
                    Text(model.overlayText.isEmpty ? "Go ahead, I'm listening" : model.overlayText)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(model.quickActive || hover ? 8 : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
                .onTapGesture { if !model.quickActive { model.showWindow() } }
                .help(model.quickActive ? "" : "Open Jarvis")
                actions
            }
            if model.busy, let running = model.steps.last {
                HStack(spacing: 8) {
                    Image(systemName: running.icon ?? "bolt.fill").foregroundStyle(model.accent).font(.caption)
                    Text(running.title).font(.caption.weight(.medium))
                    if let d = running.detail {
                        Text(d).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.steps.count > 1 { MicroLabel(text: "step \(model.steps.count)") }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            if model.quickActive {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(model.accent)
                    TextField("Type instead, or just speak…", text: $model.typed)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .rounded))
                        .focused($focused)
                        .onSubmit { model.submit(model.typed) }
                    MicroLabel(text: "esc to close")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .onAppear { focused = true }
            }
        }
        .padding(16)
        .frame(width: 600)
        .glassCard(26)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hover = h }
            model.overlayHovered = h
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(model.accent.opacity(0.4), lineWidth: 1))
        .preferredColorScheme(model.colorScheme)
        .tint(model.accent)
        .padding(10)   // room for the shadow
    }

    /// What you can do with what the bubble is showing.
    private var actions: some View {
        let answered = !model.answer.isEmpty && (model.phase == .idle || model.phase == .speaking)
        return HStack(spacing: 6) {
            if model.busy {
                OrbButton(icon: "stop.fill", tint: .red, size: 24) { model.stopEverything() }
                    .help("Stop (Esc)")
            }
            if answered {
                OrbButton(icon: "speaker.wave.2", size: 24) { model.speakAgain() }
                    .help("Read aloud")
                OrbButton(icon: "doc.on.doc", size: 24) { model.copyAnswer() }
                    .help("Copy the answer")
            }
            if !model.quickActive {
                OrbButton(icon: "macwindow", size: 24) { model.showWindow() }
                    .help("Open Jarvis")
                OrbButton(icon: "mic", size: 24) { model.hotkeyPressed() }
                    .help("Ask something else")
            }
            OrbButton(icon: "xmark", size: 24) {
                if model.quickActive { model.closeQuick() } else { model.overlayHovered = false; model.overlayVisible = false }
            }
            .help("Close")
        }
    }

    private var label: String {
        switch model.phase {
        case .idle: return model.answer.isEmpty ? "Jarvis" : "Jarvis · \(model.answerSource)"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .acting: return "Working · Esc to stop"
        case .speaking: return "Jarvis"
        }
    }
}

/// A panel that can take keyboard focus without activating Jarvis's other windows.
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private let panel: QuickPanel
    private let host: NSHostingController<AnyView>
    private var bag = Set<AnyCancellable>()
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        host = NSHostingController(rootView: AnyView(QuickView().environmentObject(model)))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 120),
                           styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.sharingType = .none   // keep it out of the screenshots the model sees
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        model.$overlayVisible.removeDuplicates().sink { [weak self] visible in
            visible ? self?.show() : self?.hide()
        }.store(in: &bag)
        // Clickable, except while Jarvis is clicking on the screen itself, so it never gets in the way.
        model.$phase.combineLatest(model.$quickActive).sink { [weak self] phase, active in
            self?.panel.ignoresMouseEvents = phase == .acting && !active
        }.store(in: &bag)
        model.$quickActive.removeDuplicates().sink { [weak self] active in
            guard let self else { return }
            if active {
                self.show()
                self.panel.makeKey()
            }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel)
            .sink { [weak self] _ in self?.place() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                guard let m = self?.model, m.quickActive, !m.busy, m.phase != .listening else { return }
                m.closeQuick()
            }
            .store(in: &bag)
    }

    /// Top centre of the screen with the pointer, just under the menu bar.
    private func place() {
        guard panel.frame.width > 10 else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 8))
    }

    private func show() {
        place()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        }
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 },
                                             completionHandler: { [panel] in if panel.alphaValue == 0 { panel.orderOut(nil) } })
    }
}
