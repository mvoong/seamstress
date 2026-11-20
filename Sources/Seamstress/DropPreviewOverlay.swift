import Cocoa
import CoreGraphics
import QuartzCore
import SeamstressCore

private final class ClickThroughPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Zero-latency borderless click-through frosted-glass overlay showing the snap-drag target zone.
final class DropPreviewOverlay {
    private var panel: NSPanel?
    private var visualEffectView: NSVisualEffectView?
    private var tintView: NSView?
    private var badgeView: NSVisualEffectView?
    private var badgeIconView: NSImageView?
    private var badgeLabel: NSTextField?

    private var lastRect: CGRect = .zero
    private var lastKind: DropPreviewKind?
    private var hideToken: UInt64 = 0
    private var isHiding: Bool = false

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(cgRect: CGRect, kind: DropPreviewKind, primaryScreenHeight: CGFloat) {
        if isVisible && !isHiding && lastRect == cgRect && lastKind == kind { return }

        hideToken &+= 1
        let wasVisible = isVisible
        let wasHiding = isHiding
        isHiding = false
        lastRect = cgRect
        lastKind = kind

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Slight visual inset so the border sits crisply inside the target tile bounds.
        let insetRect = cgRect.insetBy(dx: 4, dy: 4)
        let nsFrame = CoordinateSpace.nsRect(fromCG: insetRect, primaryHeight: primaryScreenHeight)

        let style = Self.style(for: kind)

        if let tintLayer = tintView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tintLayer.backgroundColor = style.accent.withAlphaComponent(0.18).cgColor
            tintLayer.borderColor = style.accent.withAlphaComponent(0.85).cgColor
            tintLayer.borderWidth = 2.0
            tintLayer.cornerRadius = 12
            CATransaction.commit()
        }

        let showBadge = style.badge != nil && insetRect.width >= 130 && insetRect.height >= 64
        if let badge = style.badge, showBadge {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            let icon = NSImage(systemSymbolName: badge.symbolName, accessibilityDescription: badge.title)?
                .withSymbolConfiguration(symbolConfig)
            badgeIconView?.image = icon
            badgeIconView?.contentTintColor = style.accent
            badgeLabel?.stringValue = badge.title
            badgeView?.layer?.borderColor = style.accent.withAlphaComponent(0.45).cgColor
            badgeView?.isHidden = false
        } else {
            badgeView?.isHidden = true
        }

        if !wasVisible {
            panel.setFrame(nsFrame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.07
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else if wasHiding {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.07
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(nsFrame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.07
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(nsFrame, display: true)
            }
        }
    }

    func hide(animated: Bool = false) {
        lastRect = .zero
        lastKind = nil
        hideToken &+= 1
        let token = hideToken

        guard let panel else { return }

        if animated && panel.isVisible {
            isHiding = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.06
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.hideToken == token else { return }
                self.isHiding = false
                panel.orderOut(nil)
                panel.alphaValue = 1
            })
        } else {
            isHiding = false
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private struct PreviewStyle {
        let accent: NSColor
        let badge: (symbolName: String, title: String)?
    }

    private static func style(for kind: DropPreviewKind) -> PreviewStyle {
        switch kind {
        case .fill:
            return PreviewStyle(accent: .controlAccentColor, badge: nil)
        case .split:
            return PreviewStyle(accent: .controlAccentColor, badge: nil)
        case .splitContainer:
            return PreviewStyle(
                accent: .controlAccentColor,
                badge: (symbolName: "rectangle.split.2x1", title: "Split All")
            )
        case .swap:
            return PreviewStyle(
                accent: .systemPurple,
                badge: (symbolName: "arrow.left.arrow.right", title: "Swap")
            )
        case .replace:
            return PreviewStyle(
                accent: .systemIndigo,
                badge: (symbolName: "arrow.triangle.2.circlepath", title: "Replace")
            )
        }
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

        let vfx = NSVisualEffectView(frame: .zero)
        vfx.material = .hudWindow
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = 12
        vfx.layer?.masksToBounds = true

        let tint = NSView(frame: .zero)
        tint.wantsLayer = true
        tint.layer?.cornerRadius = 12
        tint.layer?.masksToBounds = true
        tint.autoresizingMask = [.width, .height]
        vfx.addSubview(tint)

        let badge = NSVisualEffectView(frame: .zero)
        badge.material = .popover
        badge.blendingMode = .withinWindow
        badge.state = .active
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 13
        badge.layer?.masksToBounds = true
        badge.layer?.borderWidth = 1
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(stack)
        vfx.addSubview(badge)

        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: vfx.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: vfx.centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 26),

            stack.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])

        visualEffectView = vfx
        tintView = tint
        badgeView = badge
        badgeIconView = iconView
        badgeLabel = label

        p.contentView = vfx
        return p
    }
}
