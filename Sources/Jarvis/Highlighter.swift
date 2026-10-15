import SwiftUI
import AppKit
import Combine

/// Draws a ripple and a caption where Jarvis is about to click, so you can follow every move.
private struct HighlightView: View {
    @EnvironmentObject var model: AppModel
    @State private var grow = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let h = model.highlight {
                ZStack {
                    Circle()
                        .stroke(model.accent, lineWidth: 3)
                        .frame(width: 70, height: 70)
                        .scaleEffect(grow ? 1.6 : 0.4)
                        .opacity(grow ? 0 : 1)
                    Circle()
                        .fill(model.accent.opacity(0.3))
                        .frame(width: 20, height: 20)
                }
                .position(h.point)

                Text(h.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .overlay(Capsule().stroke(model.accent.opacity(0.7), lineWidth: 1))
                    .fixedSize()
                    .position(x: h.point.x, y: h.point.y + 48)
            }
        }
        .ignoresSafeArea()
        .onChange(of: model.highlight?.id) { _, _ in
            grow = false
            withAnimation(.easeOut(duration: 0.8).repeatCount(2, autoreverses: false)) { grow = true }
        }
    }
}

@MainActor
final class HighlightController {
    private let panel: NSPanel
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        panel = NSPanel(contentRect: NSScreen.main?.frame ?? .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none   // keep it out of the screenshots the model sees
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HighlightView().environmentObject(model))

        model.$highlight.map { $0 != nil }.removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            if on {
                if let f = NSScreen.main?.frame { self.panel.setFrame(f, display: false) }
                self.panel.orderFrontRegardless()
            } else {
                self.panel.orderOut(nil)
            }
        }.store(in: &bag)
    }
}
