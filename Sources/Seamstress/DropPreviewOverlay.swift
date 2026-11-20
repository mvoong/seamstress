import Cocoa
import CoreGraphics
import QuartzCore
import SeamstressCore

private final class ClickThroughPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Zero-latency borderless click-through overlay showing the Option-drag target zone.
final class DropPreviewOverlay {
    private var panel: NSPanel?
    private var lastRect: CGRect = .zero
    private var lastKind: DropPreviewKind?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(cgRect: CGRect, kind: DropPreviewKind, primaryScreenHeight: CGFloat) {
        if isVisible && lastRect == cgRect && lastKind == kind { return }
        lastRect = cgRect
        lastKind = kind

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Slight visual inset so the border sits crisply inside the target tile bounds.
        let insetRect = cgRect.insetBy(dx: 4, dy: 4)
        let nsFrame = CoordinateSpace.nsRect(fromCG: insetRect, primaryHeight: primaryScreenHeight)
        panel.setFrame(nsFrame, display: false)

        let accent: NSColor
        switch kind {
        case .fill, .split:
            accent = NSColor.controlAccentColor
        case .swap:
            accent = NSColor.systemPurple
        }

        if let layer = panel.contentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = accent.withAlphaComponent(0.18).cgColor
            layer.borderColor = accent.withAlphaComponent(0.85).cgColor
            layer.borderWidth = 2.0
            layer.cornerRadius = 10
            CATransaction.commit()
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        lastRect = .zero
        lastKind = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = ClickThroughPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.animationBehavior = .none

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        p.contentView = view
        return p
    }
}
