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
    @ObservedObject var notch: NotchState

    var body: some View {
        // Nothing to draw or update while the bar is hidden.
        // Kept on screen through the retract animation; nothing is drawn once it is tucked away.
        if notch.mounted { content } else { Color.clear.frame(width: 1, height: 1) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                LiveOrb(voice: model.voice, phase: model.phase, accent: model.accent,
                        still: model.store.value.reduceMotion || (model.phase == .idle && !model.quickActive && !hover))
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
        .padding(.horizontal, 18 + NotchShape.ear)
        .padding(.top, NotchMetrics.height + 8)      // content starts below the camera housing
        .padding(.bottom, 16)
        .frame(width: 600)
        .modifier(NotchGlass())
        .overlay(NotchShape().stroke(model.accent.opacity(model.busy ? 0.55 : 0.25), lineWidth: 1))
        // Grows out of the notch, the way the system's own notch alerts do.
        .scaleEffect(x: notch.open ? 1 : NotchMetrics.width / 600, y: notch.open ? 1 : 0.2, anchor: .top)
        .opacity(notch.open ? 1 : 0)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hover = h }
            model.overlayHovered = h
        }
        .preferredColorScheme(model.colorScheme)
        .tint(model.accent)
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
    private let notch = NotchState()
    private var hideWork: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
        host = NSHostingController(rootView: AnyView(QuickView(notch: notch).environmentObject(model)))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 120),
                           styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .statusBar + 1   // over the menu bar, where the notch lives
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
        // The panel resizes itself to its content during layout. Moving it from inside that pass makes AppKit
        // re-run constraints until it gives up and throws, so the move waits for the pass to finish.
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.place() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                guard let m = self?.model, m.quickActive, !m.busy, m.phase != .listening else { return }
                m.closeQuick()
            }
            .store(in: &bag)
    }

    /// Flush with the top edge, centred on the notch of the screen with the pointer.
    private func place() {
        guard panel.frame.width > 10 else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let f = screen.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height))
    }

    private func show() {
        hideWork?.cancel()
        place()
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        notch.mounted = true
        // Next frame, so it starts tucked in the notch and drops down from there.
        DispatchQueue.main.async { [notch] in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) { notch.open = true }
        }
    }

    private func hide() {
        guard notch.mounted else { return }
        // Retract back into the notch, then take the panel away.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { notch.open = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.notch.open else { return }
            self.notch.mounted = false
            self.panel.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
    }
}


/// Size of the screen's notch, or of the menu bar on Macs without one.
enum NotchMetrics {
    static var screen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    static var height: CGFloat {
        guard let s = screen else { return 32 }
        if s.safeAreaInsets.top > 0 { return s.safeAreaInsets.top }
        return max(24, s.frame.maxY - s.visibleFrame.maxY)
    }

    static var width: CGFloat {
        guard let s = screen, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return 200 }
        return max(160, s.frame.width - l.width - r.width)
    }
}

/// The notch silhouette: hangs from the top edge, flares into it at the shoulders, rounded at the bottom.
struct NotchShape: Shape {
    static let ear: CGFloat = 10
    var radius: CGFloat = 24

    func path(in r: CGRect) -> Path {
        let e = Self.ear
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + e + radius, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - radius), control: CGPoint(x: r.maxX - e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Whether the notch popup is dropped down, and whether it is on screen at all (it stays mounted while retracting).
@MainActor
final class NotchState: ObservableObject {
    @Published var open = false
    @Published var mounted = false
}

/// Liquid Glass in the notch's silhouette (frosted material before macOS 26).
struct NotchGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: NotchShape())
        } else {
            content.background(.ultraThinMaterial, in: NotchShape()).clipShape(NotchShape())
        }
    }
}
