import AppKit
import SwiftUI

/// Brief floating badge near the bottom of the screen, like the system volume HUD.
@MainActor
final class StatusHUD {
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }()

    // Bumped on every show so a fade from an earlier show can't hide a newer one.
    private var generation = 0

    func show(symbol: String, text: String) {
        let content = NSHostingView(rootView: HUDView(symbol: symbol, text: text))
        panel.contentView = content
        let size = content.fittingSize
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 120, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        generation += 1
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, shown == generation else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self.panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    if shown == self.generation { self.panel.orderOut(nil) }
                }
            }
        }
    }
}

private struct HUDView: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title2)
            Text(text).font(.headline)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: Capsule())
    }
}
