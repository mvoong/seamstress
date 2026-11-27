import Cocoa
import CoreGraphics
import CoreVideo
import QuartzCore
import SeamstressCore
import simd

/// Visual seam highlight shown when hovering or dragging a flush seam (or a 2-axis
/// `┼` intersection of a vertical and horizontal seam). Supports Metal-rendered animated
/// styles (`elastic`, `prism`) paced by `CVDisplayLink` as well as the classic flat accent
/// hairline, plus a full-pane expansion preview when dragging past 90% into an empty slot.
@MainActor
final class SeamHighlightOverlay {
    private enum CursorMode: Equatable {
        case none
        case vertical
        case horizontal
        case intersection
    }

    private struct LineRenderState {
        var visualRectCG: CGRect
        var axis: SplitAxis
        var isDragging: Bool
        var isClamped: Bool
        var isSnapped: Bool
        var showGrip: Bool
        var primaryScreenHeight: CGFloat
        var lastSeamCoordinate: CGFloat
        var spring: SeamElasticSpring
    }

    /// Thread-safe bridge for `CVDisplayLink` callbacks so we coalesce at most one pending
    /// main-thread tick per vsync and never retain `SeamHighlightOverlay` strongly.
    private final class DisplayLinkGate: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false
        private var active = false

        func setActive(_ isActive: Bool) {
            lock.lock()
            active = isActive
            if !isActive { pending = false }
            lock.unlock()
        }

        func claimTick() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard active, !pending else { return false }
            pending = true
            return true
        }

        func finishTick() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            pending = false
            return active
        }
    }

    private var effectStyle: SeamEffectStyle = .defaultStyle

    private var primaryLinePanel: NSPanel?
    private var primaryClassicLineLayer: CALayer?
    private var primaryGripLayer: CALayer?
    private var primaryMetalView: MetalSeamView?

    private var secondaryLinePanel: NSPanel?
    private var secondaryClassicLineLayer: CALayer?
    private var secondaryGripLayer: CALayer?
    private var secondaryMetalView: MetalSeamView?

    private var intersectionKnobPanel: NSPanel?
    private var intersectionKnobLayer: CALayer?
    private var collapsePreviewPanel: NSPanel?
    private var activeCursor: CursorMode = .none

    // Live animation state (active only while a Metal seam overlay is visible).
    private var primaryState: LineRenderState?
    private var secondaryState: LineRenderState?
    private var displayLink: CVDisplayLink?
    private let displayLinkGate = DisplayLinkGate()
    private var sessionStartUptime: TimeInterval = 0
    private var lastTickUptime: TimeInterval = 0
    private var smoothDragAmount: CGFloat = 0
    private var cachedAccentSIMD: SIMD4<Float> = SIMD4<Float>(0.25, 0.56, 1.0, 1.0)
    private var wasSnapped: Bool = false
    private var snapPulseStartUptime: TimeInterval = -10
    private var snapPulseOriginPrimary: Float = 0.5
    private var snapPulseOriginSecondary: Float = 0.5

    deinit {
        displayLinkGate.setActive(false)
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
    }

    func warmUpMetalIfNeeded() {
        if effectStyle.usesMetal {
            MetalSeamPipeline.shared.warmUpAsync()
        }
    }

    func setEffectStyle(_ style: SeamEffectStyle) {
        guard effectStyle != style else { return }
        effectStyle = style
        if style.usesMetal {
            MetalSeamPipeline.shared.warmUpAsync()
        }

        // Re-render immediately if an overlay is currently on screen.
        if let primary = primaryState {
            if let secondary = secondaryState {
                showIntersection(
                    verticalVisualCG: primary.visualRectCG,
                    horizontalVisualCG: secondary.visualRectCG,
                    isDragging: primary.isDragging,
                    isClamped: primary.isClamped,
                    isSnapped: primary.isSnapped,
                    primaryScreenHeight: primary.primaryScreenHeight,
                    forceRender: true
                )
            } else {
                showSeam(
                    visualRectCG: primary.visualRectCG,
                    axis: primary.axis,
                    isDragging: primary.isDragging,
                    isClamped: primary.isClamped,
                    isSnapped: primary.isSnapped,
                    primaryScreenHeight: primary.primaryScreenHeight,
                    forceRender: true
                )
            }
        }
    }

    func showSeam(
        visualRectCG: CGRect,
        axis: SplitAxis,
        isDragging: Bool,
        isClamped: Bool = false,
        isSnapped: Bool = false,
        primaryScreenHeight: CGFloat,
        forceRender: Bool = false
    ) {
        hideCollapsePreview()
        secondaryLinePanel?.orderOut(nil)
        intersectionKnobPanel?.orderOut(nil)
        secondaryState = nil

        let now = ProcessInfo.processInfo.systemUptime
        let wasVisible = primaryState != nil
        if !wasVisible {
            beginAnimationSession(now: now, isDragging: isDragging)
        }

        let seamCoord = (axis == .vertical) ? visualRectCG.midX : visualRectCG.midY
        var spring = primaryState?.spring ?? SeamElasticSpring()
        if !wasVisible {
            spring.applyImpulse(isDragging ? 42 : 26)
        } else if let prev = primaryState {
            let delta = seamCoord - prev.lastSeamCoordinate
            if abs(delta) > 0.5 {
                // Crisp, bounded flex that stays tight to the pointer without trailing behind.
                let impulse = max(-42.0, min(42.0, -delta * 2.2))
                spring.applyImpulse(impulse)
            }
        }

        if isSnapped && !wasSnapped && !isClamped {
            snapPulseStartUptime = now
            snapPulseOriginPrimary = cursorNormalized(along: visualRectCG, axis: axis, primaryScreenHeight: primaryScreenHeight)
            spring.applyImpulse(spring.displacement >= 0 ? -72 : 72)
        }
        wasSnapped = isSnapped

        let state = LineRenderState(
            visualRectCG: visualRectCG,
            axis: axis,
            isDragging: isDragging,
            isClamped: isClamped,
            isSnapped: isSnapped,
            showGrip: true,
            primaryScreenHeight: primaryScreenHeight,
            lastSeamCoordinate: seamCoord,
            spring: spring
        )
        primaryState = state

        let panel = primaryLinePanel ?? makeLinePanel(
            assignLine: { self.primaryClassicLineLayer = $0 },
            assignGrip: { self.primaryGripLayer = $0 },
            assignMetal: { self.primaryMetalView = $0 }
        )
        primaryLinePanel = panel

        layoutLinePanel(
            panel,
            classicLine: primaryClassicLineLayer,
            grip: primaryGripLayer,
            metalView: primaryMetalView,
            state: state
        )

        if shouldUseMetal {
            // Render synchronously only on initial reveal or style switch; during dragging,
            // moving the panel repositions the Metal layer at 0ms latency in WindowServer and
            // CVDisplayLink updates uniforms once per vsync without flooding the GPU.
            if !wasVisible || forceRender {
                renderMetalFrame(now: now)
            }
            ensureDisplayLinkRunning()
        } else {
            stopDisplayLink()
        }

        applyCursor(axis == .vertical ? .vertical : .horizontal, force: true)
    }

    func showIntersection(
        verticalVisualCG: CGRect,
        horizontalVisualCG: CGRect,
        isDragging: Bool,
        isClamped: Bool = false,
        isSnapped: Bool = false,
        primaryScreenHeight: CGFloat,
        forceRender: Bool = false
    ) {
        hideCollapsePreview()

        let now = ProcessInfo.processInfo.systemUptime
        let wasVisible = primaryState != nil
        if !wasVisible {
            beginAnimationSession(now: now, isDragging: isDragging)
        }

        var vSpring = primaryState?.spring ?? SeamElasticSpring()
        var hSpring = secondaryState?.spring ?? SeamElasticSpring()
        if !wasVisible {
            vSpring.applyImpulse(26)
            hSpring.applyImpulse(-26)
        } else {
            if let prevV = primaryState {
                let dx = verticalVisualCG.midX - prevV.lastSeamCoordinate
                if abs(dx) > 0.5 { vSpring.applyImpulse(max(-42.0, min(42.0, -dx * 2.2))) }
            }
            if let prevH = secondaryState {
                let dy = horizontalVisualCG.midY - prevH.lastSeamCoordinate
                if abs(dy) > 0.5 { hSpring.applyImpulse(max(-42.0, min(42.0, -dy * 2.2))) }
            }
        }

        let centerCG = CGPoint(x: verticalVisualCG.midX, y: horizontalVisualCG.midY)
        if isSnapped && !wasSnapped && !isClamped {
            snapPulseStartUptime = now
            snapPulseOriginPrimary = normalizedPosition(pointCG: centerCG, in: verticalVisualCG, axis: .vertical)
            snapPulseOriginSecondary = normalizedPosition(pointCG: centerCG, in: horizontalVisualCG, axis: .horizontal)
            vSpring.applyImpulse(vSpring.displacement >= 0 ? -68 : 68)
            hSpring.applyImpulse(hSpring.displacement >= 0 ? -68 : 68)
        }
        wasSnapped = isSnapped

        let vState = LineRenderState(
            visualRectCG: verticalVisualCG,
            axis: .vertical,
            isDragging: isDragging,
            isClamped: isClamped,
            isSnapped: isSnapped,
            showGrip: false,
            primaryScreenHeight: primaryScreenHeight,
            lastSeamCoordinate: verticalVisualCG.midX,
            spring: vSpring
        )
        let hState = LineRenderState(
            visualRectCG: horizontalVisualCG,
            axis: .horizontal,
            isDragging: isDragging,
            isClamped: isClamped,
            isSnapped: isSnapped,
            showGrip: false,
            primaryScreenHeight: primaryScreenHeight,
            lastSeamCoordinate: horizontalVisualCG.midY,
            spring: hSpring
        )
        primaryState = vState
        secondaryState = hState

        let vPanel = primaryLinePanel ?? makeLinePanel(
            assignLine: { self.primaryClassicLineLayer = $0 },
            assignGrip: { self.primaryGripLayer = $0 },
            assignMetal: { self.primaryMetalView = $0 }
        )
        primaryLinePanel = vPanel
        let hPanel = secondaryLinePanel ?? makeLinePanel(
            assignLine: { self.secondaryClassicLineLayer = $0 },
            assignGrip: { self.secondaryGripLayer = $0 },
            assignMetal: { self.secondaryMetalView = $0 }
        )
        secondaryLinePanel = hPanel
        let knobPanel = intersectionKnobPanel ?? makeIntersectionKnobPanel(assignKnob: { self.intersectionKnobLayer = $0 })
        intersectionKnobPanel = knobPanel

        layoutLinePanel(
            vPanel,
            classicLine: primaryClassicLineLayer,
            grip: primaryGripLayer,
            metalView: primaryMetalView,
            state: vState
        )
        layoutLinePanel(
            hPanel,
            classicLine: secondaryClassicLineLayer,
            grip: secondaryGripLayer,
            metalView: secondaryMetalView,
            state: hState
        )
        layoutIntersectionKnob(
            knobPanel,
            knob: intersectionKnobLayer,
            centerCG: centerCG,
            isDragging: isDragging,
            isClamped: isClamped,
            isSnapped: isSnapped,
            primaryScreenHeight: primaryScreenHeight
        )

        if shouldUseMetal {
            if !wasVisible || forceRender {
                renderMetalFrame(now: now)
            }
            ensureDisplayLinkRunning()
        } else {
            stopDisplayLink()
        }

        applyCursor(.intersection, force: true)
    }

    func showCollapsePreview(expandedBoundsCG: CGRect, axis: SplitAxis, primaryScreenHeight: CGFloat) {
        stopDisplayLink()
        primaryState = nil
        secondaryState = nil
        wasSnapped = false
        primaryLinePanel?.orderOut(nil)
        secondaryLinePanel?.orderOut(nil)
        intersectionKnobPanel?.orderOut(nil)

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
        applyCursor(axis == .vertical ? .vertical : .horizontal, force: true)
    }

    func reassertCursor() {
        guard activeCursor != .none else { return }
        applyCursor(activeCursor, force: true)
    }

    func hide() {
        stopDisplayLink()
        primaryState = nil
        secondaryState = nil
        wasSnapped = false
        primaryLinePanel?.orderOut(nil)
        secondaryLinePanel?.orderOut(nil)
        intersectionKnobPanel?.orderOut(nil)
        hideCollapsePreview()
        clearCursor()
    }

    // MARK: - Vsync-Paced Display Link

    private var shouldUseMetal: Bool {
        effectStyle.usesMetal && MetalSeamPipeline.shared.isAvailable
    }

    private func beginAnimationSession(now: TimeInterval, isDragging: Bool) {
        sessionStartUptime = now
        lastTickUptime = now
        smoothDragAmount = isDragging ? 1.0 : 0.0
        cachedAccentSIMD = resolvedAccentSIMD()
        wasSnapped = false
        snapPulseStartUptime = -10
    }

    private func ensureDisplayLinkRunning() {
        displayLinkGate.setActive(true)
        if let link = displayLink {
            if !CVDisplayLinkIsRunning(link) {
                CVDisplayLinkStart(link)
            }
            return
        }

        var linkOut: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&linkOut) == kCVReturnSuccess,
              let link = linkOut else {
            return
        }

        let gate = displayLinkGate
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            guard gate.claimTick() else { return kCVReturnSuccess }
            DispatchQueue.main.async {
                guard gate.finishTick() else { return }
                self?.displayLinkTick()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLinkGate.setActive(false)
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
    }

    private func displayLinkTick() {
        guard shouldUseMetal, primaryState != nil else {
            stopDisplayLink()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(1.0 / 240.0, min(now - lastTickUptime, 1.0 / 20.0))
        lastTickUptime = now

        if var p = primaryState {
            let targetDrag: CGFloat = p.isDragging ? 1.0 : 0.0
            smoothDragAmount += (targetDrag - smoothDragAmount) * min(1.0, CGFloat(dt) * 20.0)
            p.spring.step(dt: CGFloat(dt), target: 0)
            primaryState = p
        }
        if var s = secondaryState {
            s.spring.step(dt: CGFloat(dt), target: 0)
            secondaryState = s
        }

        renderMetalFrame(now: now)
    }

    private func renderMetalFrame(now: TimeInterval) {
        let elapsed = Float(max(0, now - sessionStartUptime))
        let revealDuration: Float = 0.16
        let rawReveal = min(1.0, elapsed / revealDuration)
        let hoverProgress = 1.0 - pow(1.0 - rawReveal, 3.0)
        let snapAge: Float = (snapPulseStartUptime > 0) ? Float(now - snapPulseStartUptime) : -1.0

        if let p = primaryState, let metalView = primaryMetalView {
            let cursorNorm: Float
            if let s = secondaryState {
                let center = CGPoint(x: p.visualRectCG.midX, y: s.visualRectCG.midY)
                cursorNorm = normalizedPosition(pointCG: center, in: p.visualRectCG, axis: p.axis)
            } else {
                cursorNorm = cursorNormalized(along: p.visualRectCG, axis: p.axis, primaryScreenHeight: p.primaryScreenHeight)
            }

            let uniforms = SeamShaderUniforms(
                resolution: SIMD2<Float>(Float(metalView.bounds.width), Float(metalView.bounds.height)),
                accentColor: cachedAccentSIMD,
                time: elapsed,
                cursorAlong: cursorNorm,
                hoverProgress: hoverProgress,
                dragAmount: Float(smoothDragAmount),
                bowOffset: Float(p.spring.displacement),
                snapPulseAge: snapAge,
                snapPulseOrigin: snapPulseOriginPrimary,
                mode: effectStyle.shaderModeIndex,
                isHorizontal: p.axis == .horizontal ? 1 : 0,
                isClamped: p.isClamped ? 1 : 0,
                isSnapped: p.isSnapped ? 1 : 0,
                showGrip: p.showGrip ? 1 : 0
            )
            metalView.render(uniforms: uniforms)
        }

        if let s = secondaryState, let p = primaryState, let metalView = secondaryMetalView {
            let center = CGPoint(x: p.visualRectCG.midX, y: s.visualRectCG.midY)
            let cursorNorm = normalizedPosition(pointCG: center, in: s.visualRectCG, axis: s.axis)

            let uniforms = SeamShaderUniforms(
                resolution: SIMD2<Float>(Float(metalView.bounds.width), Float(metalView.bounds.height)),
                accentColor: cachedAccentSIMD,
                time: elapsed,
                cursorAlong: cursorNorm,
                hoverProgress: hoverProgress,
                dragAmount: Float(smoothDragAmount),
                bowOffset: Float(s.spring.displacement),
                snapPulseAge: snapAge,
                snapPulseOrigin: snapPulseOriginSecondary,
                mode: effectStyle.shaderModeIndex,
                isHorizontal: s.axis == .horizontal ? 1 : 0,
                isClamped: s.isClamped ? 1 : 0,
                isSnapped: s.isSnapped ? 1 : 0,
                showGrip: s.showGrip ? 1 : 0
            )
            metalView.render(uniforms: uniforms)
        }
    }

    private func cursorNormalized(along visualRectCG: CGRect, axis: SplitAxis, primaryScreenHeight: CGFloat) -> Float {
        let mouseNS = NSEvent.mouseLocation
        let mouseCG = CGPoint(x: mouseNS.x, y: primaryScreenHeight - mouseNS.y)
        return normalizedPosition(pointCG: mouseCG, in: visualRectCG, axis: axis)
    }

    private func normalizedPosition(pointCG: CGPoint, in rectCG: CGRect, axis: SplitAxis) -> Float {
        switch axis {
        case .vertical:
            guard rectCG.height > 1 else { return 0.5 }
            return Float(max(0, min(1, (pointCG.y - rectCG.minY) / rectCG.height)))
        case .horizontal:
            guard rectCG.width > 1 else { return 0.5 }
            return Float(max(0, min(1, (pointCG.x - rectCG.minX) / rectCG.width)))
        }
    }

    private func resolvedAccentSIMD() -> SIMD4<Float> {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB)
            ?? NSColor.systemBlue.usingColorSpace(.sRGB)
        return SIMD4<Float>(
            Float(color?.redComponent ?? 0.25),
            Float(color?.greenComponent ?? 0.56),
            Float(color?.blueComponent ?? 1.0),
            1.0
        )
    }

    // MARK: - Panel Layout

    private func hideCollapsePreview() {
        collapsePreviewPanel?.orderOut(nil)
    }

    private func layoutLinePanel(
        _ panel: NSPanel,
        classicLine: CALayer?,
        grip: CALayer?,
        metalView: MetalSeamView?,
        state: LineRenderState
    ) {
        let useMetal = shouldUseMetal
        let envelopeThickness = useMetal ? effectStyle.envelopeThickness : SeamEffectStyle.classic.envelopeThickness
        let panelCG: CGRect
        switch state.axis {
        case .vertical:
            panelCG = CGRect(
                x: (state.visualRectCG.midX - envelopeThickness * 0.5).rounded(),
                y: state.visualRectCG.minY.rounded(),
                width: envelopeThickness,
                height: state.visualRectCG.height.rounded()
            )
        case .horizontal:
            panelCG = CGRect(
                x: state.visualRectCG.minX.rounded(),
                y: (state.visualRectCG.midY - envelopeThickness * 0.5).rounded(),
                width: state.visualRectCG.width.rounded(),
                height: envelopeThickness
            )
        }

        let nsFrame = CoordinateSpace.nsRect(fromCG: panelCG, primaryHeight: state.primaryScreenHeight)
        let currentFrame = panel.frame
        let sizeChanged = abs(currentFrame.width - nsFrame.width) > 0.5 || abs(currentFrame.height - nsFrame.height) > 0.5
        if sizeChanged {
            panel.setFrame(nsFrame, display: false)
        } else if abs(currentFrame.origin.x - nsFrame.origin.x) > 0.5 || abs(currentFrame.origin.y - nsFrame.origin.y) > 0.5 {
            // Origin-only move avoids triggering subview resize / CAMetalLayer drawable reallocation.
            panel.setFrameOrigin(nsFrame.origin)
        }

        if let metalView {
            if sizeChanged || metalView.frame.size != nsFrame.size {
                metalView.frame = CGRect(origin: .zero, size: nsFrame.size)
            }
            if metalView.isHidden != !useMetal {
                metalView.isHidden = !useMetal
            }
        }

        if let classicLine, let grip {
            if useMetal {
                if !classicLine.isHidden || !grip.isHidden {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    classicLine.isHidden = true
                    grip.isHidden = true
                    CATransaction.commit()
                }
            } else {
                let tint = state.isClamped ? NSColor.systemOrange : NSColor.controlAccentColor
                let snapHighlight = state.isSnapped && !state.isClamped
                let lineAlpha: CGFloat
                let pillAlpha: CGFloat
                if snapHighlight {
                    lineAlpha = state.isDragging ? 1.0 : 0.85
                    pillAlpha = 1.0
                } else if state.isClamped {
                    lineAlpha = state.isDragging ? 0.95 : 0.78
                    pillAlpha = 1.0
                } else {
                    lineAlpha = state.isDragging ? 0.95 : 0.72
                    pillAlpha = state.isDragging ? 1.0 : 0.90
                }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                classicLine.isHidden = false
                grip.isHidden = !state.showGrip
                switch state.axis {
                case .vertical:
                    classicLine.frame = CGRect(x: (envelopeThickness - 2) * 0.5, y: 0, width: 2, height: nsFrame.height)
                    let pillH: CGFloat = min(44, max(20, nsFrame.height * 0.2))
                    grip.frame = CGRect(x: (envelopeThickness - 6) * 0.5, y: (nsFrame.height - pillH) * 0.5, width: 6, height: pillH)
                case .horizontal:
                    classicLine.frame = CGRect(x: 0, y: (envelopeThickness - 2) * 0.5, width: nsFrame.width, height: 2)
                    let pillW: CGFloat = min(44, max(20, nsFrame.width * 0.2))
                    grip.frame = CGRect(x: (nsFrame.width - pillW) * 0.5, y: (envelopeThickness - 6) * 0.5, width: pillW, height: 6)
                }
                classicLine.backgroundColor = tint.withAlphaComponent(lineAlpha).cgColor
                grip.backgroundColor = tint.withAlphaComponent(pillAlpha).cgColor
                grip.cornerRadius = 3
                if snapHighlight {
                    grip.borderWidth = 1
                    grip.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
                } else {
                    grip.borderWidth = 0
                    grip.borderColor = nil
                }
                CATransaction.commit()
            }
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func layoutIntersectionKnob(
        _ panel: NSPanel,
        knob: CALayer?,
        centerCG: CGPoint,
        isDragging: Bool,
        isClamped: Bool,
        isSnapped: Bool,
        primaryScreenHeight: CGFloat
    ) {
        let panelSize: CGFloat = effectStyle.usesMetal ? 22 : 18
        let knobSize: CGFloat = effectStyle.usesMetal ? 13 : 12
        let panelCG = CGRect(
            x: (centerCG.x - panelSize * 0.5).rounded(),
            y: (centerCG.y - panelSize * 0.5).rounded(),
            width: panelSize,
            height: panelSize
        )
        let nsFrame = CoordinateSpace.nsRect(fromCG: panelCG, primaryHeight: primaryScreenHeight)
        if panel.frame.size == nsFrame.size {
            panel.setFrameOrigin(nsFrame.origin)
        } else {
            panel.setFrame(nsFrame, display: false)
        }

        if let knob {
            let tint = isClamped ? NSColor.systemOrange : NSColor.controlAccentColor
            let snapHighlight = isSnapped && !isClamped
            let knobAlpha: CGFloat = (isDragging || isClamped || snapHighlight) ? 1.0 : 0.92
            let inset = (panelSize - knobSize) * 0.5

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            knob.frame = CGRect(x: inset, y: inset, width: knobSize, height: knobSize)
            knob.cornerRadius = knobSize * 0.5
            knob.backgroundColor = tint.withAlphaComponent(knobAlpha).cgColor

            if effectStyle.usesMetal {
                knob.borderWidth = snapHighlight ? 1.75 : 1.25
                knob.borderColor = NSColor.white.withAlphaComponent(snapHighlight ? 0.95 : 0.78).cgColor
                knob.shadowColor = tint.cgColor
                knob.shadowOpacity = isDragging ? 0.85 : 0.55
                knob.shadowRadius = 4.0
            } else {
                knob.shadowColor = NSColor.black.cgColor
                knob.shadowOpacity = 0.30
                knob.shadowRadius = 2.5
                if snapHighlight {
                    knob.borderWidth = 1
                    knob.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
                } else {
                    knob.borderWidth = 0
                    knob.borderColor = nil
                }
            }
            CATransaction.commit()
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func applyCursor(_ mode: CursorMode, force: Bool = false) {
        guard force || activeCursor != mode else { return }
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

    private func makeLinePanel(
        assignLine: (CALayer) -> Void,
        assignGrip: (CALayer) -> Void,
        assignMetal: (MetalSeamView) -> Void
    ) -> NSPanel {
        let p = OverlayPanel.make(level: .statusBar)

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

        let metalView = MetalSeamView(frame: .zero)
        metalView.autoresizingMask = [.width, .height]
        view.addSubview(metalView)

        assignLine(lineLayer)
        assignGrip(grip)
        assignMetal(metalView)
        p.contentView = view
        return p
    }

    private func makeIntersectionKnobPanel(assignKnob: (CALayer) -> Void) -> NSPanel {
        let p = OverlayPanel.make(level: .statusBar)

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        let knob = CALayer()
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.30
        knob.shadowRadius = 2.5
        knob.shadowOffset = .zero
        view.layer?.addSublayer(knob)
        assignKnob(knob)
        p.contentView = view
        return p
    }

    private func makeCollapsePanel() -> NSPanel {
        let p = OverlayPanel.make(level: .floating)

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        p.contentView = view
        return p
    }
}
