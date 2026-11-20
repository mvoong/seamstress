import Cocoa
import CoreGraphics
import QuartzCore
import SeamstressCore

private final class NonActivatingSeamPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Visual hairline + grip pill shown when hovering or dragging a flush seam (or a 2-axis
/// `┼` intersection of a vertical and horizontal seam). Also renders a full-pane expansion
/// preview when dragging a seam past 90% into an empty slot.
final class SeamHighlightOverlay {
    private enum CursorMode: Equatable {
        case none
        case vertical
        case horizontal
        case intersection
    }

    private var primaryLinePanel: NSPanel?
    private var primaryGripLayer: CALayer?
    private var secondaryLinePanel: NSPanel?
    private var secondaryGripLayer: CALayer?
    private var collapsePreviewPanel: NSPanel?
    private var activeCursor: CursorMode = .none

    func showSeam(
        visualRectCG: CGRect,
        axis: SplitAxis,
        isDragging: Bool,
        primaryScreenHeight: CGFloat
    ) {
        hideCollapsePreview()
        secondaryLinePanel?.orderOut(nil)

        let panel = primaryLinePanel ?? makeLinePanel(assignGrip: { self.primaryGripLayer = $0 })
        primaryLinePanel = panel

        layoutLinePanel(
            panel,
            grip: primaryGripLayer,
            visualRectCG: visualRectCG,
            axis: axis,
            isDragging: isDragging,
            primaryScreenHeight: primaryScreenHeight
        )
        applyCursor(axis == .vertical ? .vertical : .horizontal)
    }

    func showIntersection(
        verticalVisualCG: CGRect,
        horizontalVisualCG: CGRect,
        isDragging: Bool,
        primaryScreenHeight: CGFloat
    ) {
        hideCollapsePreview()

        let vPanel = primaryLinePanel ?? makeLinePanel(assignGrip: { self.primaryGripLayer = $0 })
        primaryLinePanel = vPanel
        let hPanel = secondaryLinePanel ?? makeLinePanel(assignGrip: { self.secondaryGripLayer = $0 })
        secondaryLinePanel = hPanel

        layoutLinePanel(
            vPanel,
            grip: primaryGripLayer,
            visualRectCG: verticalVisualCG,
            axis: .vertical,
            isDragging: isDragging,
            primaryScreenHeight: primaryScreenHeight
        )
        layoutLinePanel(
            hPanel,
            grip: secondaryGripLayer,
            visualRectCG: horizontalVisualCG,
            axis: .horizontal,
            isDragging: isDragging,
            primaryScreenHeight: primaryScreenHeight
        )
        applyCursor(.intersection)
    }

    func showCollapsePreview(expandedBoundsCG: CGRect, axis: SplitAxis, primaryScreenHeight: CGFloat) {
        primaryLinePanel?.orderOut(nil)
        secondaryLinePanel?.orderOut(nil)

        let panel = self.collapsePreviewPanel ?? makeCollapsePanel()
        self.collapsePreviewPanel = panel

        let inset = expandedBoundsCG.insetBy(dx: 4, dy: 4)
        let nsFrame = CoordinateSpace.nsRect(fromCG: inset, primaryHeight: primaryScreenHeight)
        panel.setFrame(nsFrame, display: false)

        if let layer = panel.contentView?.layer {
            let accent = NSColor.controlAccentColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = accent.withAlphaComponent(0.16).cgColor
            layer.borderColor = accent.withAlphaComponent(0.9).cgColor
            layer.borderWidth = 2.0
            layer.cornerRadius = 10
            CATransaction.commit()
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        applyCursor(axis == .vertical ? .vertical : .horizontal)
    }

    func hide() {
        primaryLinePanel?.orderOut(nil)
        secondaryLinePanel?.orderOut(nil)
        hideCollapsePreview()
        clearCursor()
    }

    private func hideCollapsePreview() {
        collapsePreviewPanel?.orderOut(nil)
    }

    private func layoutLinePanel(
        _ panel: NSPanel,
        grip: CALayer?,
        visualRectCG: CGRect,
        axis: SplitAxis,
        isDragging: Bool,
        primaryScreenHeight: CGFloat
    ) {
        let envelopeThickness: CGFloat = 10
        let panelCG: CGRect
        switch axis {
        case .vertical:
            panelCG = CGRect(
                x: visualRectCG.midX - envelopeThickness * 0.5,
                y: visualRectCG.minY,
                width: envelopeThickness,
                height: visualRectCG.height
            )
        case .horizontal:
            panelCG = CGRect(
                x: visualRectCG.minX,
                y: visualRectCG.midY - envelopeThickness * 0.5,
                width: visualRectCG.width,
                height: envelopeThickness
            )
        }

        let nsFrame = CoordinateSpace.nsRect(fromCG: panelCG, primaryHeight: primaryScreenHeight)
        panel.setFrame(nsFrame, display: false)

        if let rootLayer = panel.contentView?.layer,
           let lineLayer = rootLayer.sublayers?.first,
           let grip {
            let accent = NSColor.controlAccentColor
            let lineAlpha: CGFloat = isDragging ? 0.95 : 0.72
            let pillAlpha: CGFloat = isDragging ? 1.0 : 0.90

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            switch axis {
            case .vertical:
                lineLayer.frame = CGRect(x: (envelopeThickness - 2) * 0.5, y: 0, width: 2, height: nsFrame.height)
                let pillH: CGFloat = min(44, max(20, nsFrame.height * 0.2))
                grip.frame = CGRect(x: (envelopeThickness - 6) * 0.5, y: (nsFrame.height - pillH) * 0.5, width: 6, height: pillH)
            case .horizontal:
                lineLayer.frame = CGRect(x: 0, y: (envelopeThickness - 2) * 0.5, width: nsFrame.width, height: 2)
                let pillW: CGFloat = min(44, max(20, nsFrame.width * 0.2))
                grip.frame = CGRect(x: (nsFrame.width - pillW) * 0.5, y: (envelopeThickness - 6) * 0.5, width: pillW, height: 6)
            }
            lineLayer.backgroundColor = accent.withAlphaComponent(lineAlpha).cgColor
            grip.backgroundColor = accent.withAlphaComponent(pillAlpha).cgColor
            grip.cornerRadius = 3
            CATransaction.commit()
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func applyCursor(_ mode: CursorMode) {
        guard activeCursor != mode else { return }
        activeCursor = mode
        switch mode {
        case .none:
            NSCursor.arrow.set()
        case .vertical:
            NSCursor.resizeLeftRight.set()
        case .horizontal:
            NSCursor.resizeUpDown.set()
        case .intersection:
            NSCursor.crosshair.set()
        }
    }

    private func clearCursor() {
        guard activeCursor != .none else { return }
        activeCursor = .none
        NSCursor.arrow.set()
    }

    private func makeLinePanel(assignGrip: (CALayer) -> Void) -> NSPanel {
        let p = NonActivatingSeamPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.animationBehavior = .none

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        let lineLayer = CALayer()
        let grip = CALayer()
        grip.shadowColor = NSColor.black.cgColor
        grip.shadowOpacity = 0.25
        grip.shadowRadius = 2
        grip.shadowOffset = .zero
        view.layer?.addSublayer(lineLayer)
        view.layer?.addSublayer(grip)
        assignGrip(grip)
        p.contentView = view
        return p
    }

    private func makeCollapsePanel() -> NSPanel {
        let p = NonActivatingSeamPanel(
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
