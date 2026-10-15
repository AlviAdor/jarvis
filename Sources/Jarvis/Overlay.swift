import SwiftUI
import AppKit
import Combine

private struct OverlayView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            OrbView(phase: model.phase, accent: model.accent, still: model.store.value.reduceMotion)
                .frame(width: 64, height: 64)
            Text(model.overlayText.isEmpty ? "Listening" : model.overlayText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: 380, height: 96)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(model.accent.opacity(0.5), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}

/// Small floating HUD that appears while Jarvis is working and fades away afterwards.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 96),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView().environmentObject(model))

        model.$overlayVisible.removeDuplicates().sink { [weak self] visible in
            visible ? self?.show() : self?.hide()
        }.store(in: &bag)
    }

    private func show() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - 190, y: f.maxY - 110))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 },
                                             completionHandler: { [panel] in if panel.alphaValue == 0 { panel.orderOut(nil) } })
    }
}
