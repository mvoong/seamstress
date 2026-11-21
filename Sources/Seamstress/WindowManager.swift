import Cocoa
import CoreGraphics
import Foundation
import SeamstressCore

/// Top-level coordinator connecting `InputEventTap`, `DisplayObserver`, `SpaceLayoutStore`,
/// `AXWindowBridge`, `WindowEventMonitor`, and the live visual overlays.
final class WindowManager: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var activeLayoutLeaves: [LeafPlacement] = []
    @Published private(set) var activeDisplayBounds: CGRect = .zero
    @Published private(set) var activeDisplayName: String = ""
    @Published private(set) var canEqualizeCurrentSpace: Bool = false
    @Published private(set) var tiledWindowCount: Int = 0

    private let displayObserver = DisplayObserver()
    private let store = SpaceLayoutStore()
    private let axBridge = AXWindowBridge()
    private let eventMonitor = WindowEventMonitor()
    private let inputTap = InputEventTap()
    private let dropOverlay = DropPreviewOverlay()
    private let seamOverlay = SeamHighlightOverlay()

    /// Grace window (seconds) during which pressing Option right after starting a normal drag
    /// of a tiled window restores the pre-detach layout so swapping/re-splitting still works.
    private static let lateOptionGraceWindow: TimeInterval = 0.45

    // MARK: - Active drag states (main thread only)

    private struct WindowDragSession {
        enum Phase {
            case pending
            case moving
            case ignored
        }
        let window: CGWindowSnapshot
        let pressPoint: CGPoint
        let preDragFrame: CGRect
        let startedWithGestureDragModifier: Bool
        var phase: Phase = .pending
        var currentPlan: DropPlan?
        var detachUndo: DetachUndoSnapshot?
        var detachedAt: TimeInterval?
    }

    private struct SeamDragSession {
        let hit: SeamHit
        let screenBounds: CGRect
        let involvedPIDs: Set<pid_t>
        let initialPoint: CGPoint
        let initialRatios: [NodeID: CGFloat]
        let grabOffsets: [NodeID: CGFloat]
        var hasMoved: Bool = false
        var lastPoint: CGPoint
        var lastShiftDown: Bool = false
        var lastRatios: [NodeID: CGFloat]
        var lastCollapseTarget: SeamCollapseTarget = .none
        var lastSnapKey: String = ""
        var lastWasClamped: Bool = false
    }

    private var windowDrag: WindowDragSession?
    private var seamDrag: SeamDragSession?
    /// Spaces already probed for existing tiled layouts since launch (so manually cleared
    /// Spaces are never re-adopted on later Space switches).
    private var probedSpaces: Set<SpaceKey> = []
    private var pendingAdoptionRetry: DispatchWorkItem?
    private var adoptionRetryCount: Int = 0
    private var pendingTopologyReapply: DispatchWorkItem?
    /// Suppresses `runSanitySweep()` briefly after wake, unlock, or display topology changes
    /// so transient WindowServer transitions never evict live tiled windows.
    private var sanitySweepSuppressedUntil: TimeInterval = 0
    private static let postWakeSweepGrace: TimeInterval = 2.5
    private static let savedFloatingFramesDefaultsKey = "seamstress.savedFloatingFrames"
    private static let maxPersistedFloatingFrames = 64

    init() {
        wireCallbacks()
    }

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else { return }

        SkyLightBridge.shared.enableBackgroundCursor()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXWindowBridge.axTimeout)

        loadSavedFloatingFrames()
        displayObserver.refresh()
        displayObserver.startObserving()
        eventMonitor.start()

        guard inputTap.start() else {
            SeamstressLog.lifecycle.error("Failed to create CGEventTap")
            displayObserver.stopObserving()
            eventMonitor.stop()
            return
        }

        isRunning = true
        SeamstressLog.lifecycle.notice("Seamstress started")
        adoptExistingLayoutsIfNeeded()
        refreshSeamsAndUI()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pendingTopologyReapply?.cancel()
        pendingTopologyReapply = nil
        pendingAdoptionRetry?.cancel()
        pendingAdoptionRetry = nil
        adoptionRetryCount = 0

        persistSavedFloatingFrames()
        inputTap.setHasActiveWindowMove(false)
        inputTap.stop()
        eventMonitor.stop()
        displayObserver.stopObserving()
        dropOverlay.hide()
        seamOverlay.hide()
        windowDrag = nil
        seamDrag = nil
        SeamstressLog.lifecycle.notice("Seamstress stopped")
    }

    /// Refresh menu-bar / standalone window state for the display under the cursor.
    func refreshForMenuPresentation() {
        updateMenuState()
    }

    /// Reset all splits in the active Space on the current display back to 50/50.
    func equalizeCurrentSpaceLayout() {
        guard let display = currentMenuDisplay() else { return }
        guard let frames = store.equalizeSplits(in: display.spaceKey, screenBounds: display.usableFrameCG) else {
            return
        }
        axBridge.applyFrames(frames, crossMonitorSafe: false)
        SeamstressLog.layout.info("Equalized splits for space \(display.spaceKey.description, privacy: .public)")
        refreshSeamsAndUI()
    }

    func appInfo(for windowID: WindowID) -> WindowAppInfo? {
        axBridge.appInfo(for: windowID)
    }

    func focusWindow(_ windowID: WindowID) {
        axBridge.focusWindow(windowID: windowID)
    }

    /// Clear all tiled slots on the display under the mouse (or primary display).
    func resetCurrentSpaceLayout() {
        guard let display = currentMenuDisplay() else { return }
        let space = display.spaceKey
        let wids = store.tree(for: space).allWindowIDs
        for wid in wids {
            _ = store.handleWindowUnavailable(wid)
        }
        SeamstressLog.layout.info("Cleared layout for space \(space.description, privacy: .public) (\(wids.count) windows)")
        refreshSeamsAndUI()
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        displayObserver.onDisplaysOrSpacesChanged = { [weak self] topologyChanged in
            guard let self, self.isRunning else { return }
            self.dropOverlay.hide()
            self.inputTap.setHasActiveWindowMove(false)
            self.seamOverlay.hide()
            self.windowDrag = nil
            self.seamDrag = nil

            if topologyChanged {
                self.suppressSanitySweepForWakeGrace()
                self.scheduleDebouncedTopologyReapply()
            } else {
                self.adoptExistingLayoutsIfNeeded()
            }
            self.refreshSeamsAndUI()
        }

        displayObserver.onSessionActivityChanged = { [weak self] isActive in
            guard let self, self.isRunning else { return }
            if !isActive {
                self.dropOverlay.hide()
                self.inputTap.setHasActiveWindowMove(false)
                self.seamOverlay.hide()
                self.windowDrag = nil
                self.seamDrag = nil
                SeamstressLog.lifecycle.info("Session inactive (sleep/lock) — pausing sanity sweeps")
            } else {
                self.suppressSanitySweepForWakeGrace()
                SeamstressLog.lifecycle.info("Session active (wake/unlock) — resuming after grace window")
            }
        }

        eventMonitor.onWindowBecameUnavailable = { [weak self] wid in
            guard let self, self.isRunning else { return }
            if let space = self.store.handleWindowUnavailable(wid) {
                SeamstressLog.layout.info("Window \(wid) unavailable — expanding siblings in \(space.description, privacy: .public)")
                self.axBridge.forget(windowID: wid)
                self.applyFramesIfActive(spaces: [space])
                self.refreshSeamsAndUI()
            }
        }

        eventMonitor.onApplicationUnavailable = { [weak self] pid in
            guard let self, self.isRunning else { return }
            var affectedSpaces: Set<SpaceKey> = []
            for wid in self.store.allTiledWindowIDs {
                if self.axBridge.pid(for: wid) == pid {
                    if let space = self.store.handleWindowUnavailable(wid) {
                        affectedSpaces.insert(space)
                    }
                    self.axBridge.forget(windowID: wid)
                }
            }
            if !affectedSpaces.isEmpty {
                SeamstressLog.layout.info("PID \(pid) hid/quit — expanding siblings in \(affectedSpaces.count) space(s)")
                self.applyFramesIfActive(spaces: affectedSpaces)
                self.refreshSeamsAndUI()
            }
        }

        eventMonitor.onApplicationTerminated = { [weak self] pid in
            self?.axBridge.evictTerminatedPID(pid)
        }

        eventMonitor.onSanitySweep = { [weak self] in
            self?.runSanitySweep()
        }

        inputTap.onHoverCandidateChanged = { [weak self] hit, point in
            self?.handleHoverCandidate(hit, at: point)
        }

        inputTap.onHoverCursorReassert = { [weak self] in
            self?.seamOverlay.reassertCursor()
        }

        inputTap.isSeamHitUnoccludedSync = { [weak self] hit, point in
            guard let self else { return false }
            return !self.axBridge.isSeamPointOccluded(point, allowedWindowIDs: hit.participatingWindowIDs)
        }

        inputTap.topWindowAtPointSync = { [weak self] point in
            guard let self, let win = self.axBridge.topWindow(at: point) else { return nil }
            return (win.windowID, win.ownerPID)
        }

        inputTap.onSeamDragBegin = { [weak self] hit, point in
            self?.handleSeamDragBegin(hit, at: point)
        }

        inputTap.onSeamDragMove = { [weak self] _, point, shiftDown in
            self?.handleSeamDragMove(to: point, shiftDown: shiftDown)
        }

        inputTap.onSeamShiftChangedDuringDrag = { [weak self] shiftDown, point in
            self?.handleSeamDragMove(to: point, shiftDown: shiftDown)
        }

        inputTap.onSeamDragEnd = { [weak self] _, point in
            self?.handleSeamDragEnd(at: point)
        }

        inputTap.onSeamDragCancel = { [weak self] in
            self?.handleSeamDragCancel()
        }

        inputTap.onSeamDoubleClick = { [weak self] hit in
            self?.handleSeamDoubleClick(hit)
        }

        inputTap.onWindowMouseDown = { [weak self] point, snapModifierDown, isGestureDrag in
            self?.handleWindowMouseDown(at: point, snapModifierDown: snapModifierDown, isGestureDrag: isGestureDrag)
        }

        inputTap.onWindowMouseDragged = { [weak self] point, snapModifierDown in
            self?.handleWindowMouseDragged(to: point, snapModifierDown: snapModifierDown)
        }

        inputTap.onWindowMouseUp = { [weak self] point, snapModifierDown in
            self?.handleWindowMouseUp(at: point, snapModifierDown: snapModifierDown)
        }

        inputTap.onWindowDragCancel = { [weak self] in
            self?.handleWindowDragCancel()
        }

        inputTap.onSnapModifierChangedDuringDrag = { [weak self] snapModifierDown, point in
            self?.handleSnapModifierChangedDuringDrag(snapModifierDown: snapModifierDown, point: point)
        }
    }

    // MARK: - Seam hover, drag & double-click (single seam + 2-axis intersection)

    private func handleHoverCandidate(_ hit: SeamHit?, at point: CGPoint) {
        guard isRunning, seamDrag == nil, windowDrag == nil else {
            inputTap.setUnoccludedHoverHit(nil)
            seamOverlay.hide()
            return
        }

        guard let hit else {
            inputTap.setUnoccludedHoverHit(nil)
            seamOverlay.hide()
            return
        }

        // Verify no floating window sits on top of the seam at `point`.
        if axBridge.isSeamPointOccluded(point, allowedWindowIDs: hit.participatingWindowIDs) {
            inputTap.setUnoccludedHoverHit(nil)
            seamOverlay.hide()
            return
        }

        inputTap.setUnoccludedHoverHit(hit)
        switch hit {
        case .single(let seam):
            seamOverlay.showSeam(
                visualRectCG: seam.visualRect,
                axis: seam.axis,
                isDragging: false,
                primaryScreenHeight: displayObserver.primaryScreenHeight
            )
        case .intersection(let vs, let hs):
            let vUnion = unionVisualRect(of: vs)
            let hUnion = unionVisualRect(of: hs)
            seamOverlay.showIntersection(
                verticalVisualCG: vUnion,
                horizontalVisualCG: hUnion,
                isDragging: false,
                primaryScreenHeight: displayObserver.primaryScreenHeight
            )
        }
    }

    private func handleSeamDragBegin(_ hit: SeamHit, at point: CGPoint) {
        guard isRunning, let bounds = displayObserver.usableBounds(for: hit.spaceKey) else { return }

        // Refresh declared minimum sizes once via SkyLight (fast, zero AX IPC) and resolve PIDs.
        var pids: Set<pid_t> = []
        for wid in hit.participatingWindowIDs {
            if let pid = axBridge.pid(for: wid) {
                pids.insert(pid)
            }
            recordDeclaredMinSizeIfAvailable(for: wid)
        }
        axBridge.beginLiveResizeBatch(pids: pids)

        var ratios: [NodeID: CGFloat] = [:]
        var grabOffsets: [NodeID: CGFloat] = [:]
        for seam in hit.allSeams {
            ratios[seam.splitID] = seam.ratio
            grabOffsets[seam.splitID] = seam.axis == .vertical
                ? (point.x - seam.seamPosition)
                : (point.y - seam.seamPosition)
        }

        seamDrag = SeamDragSession(
            hit: hit,
            screenBounds: bounds,
            involvedPIDs: pids,
            initialPoint: point,
            initialRatios: ratios,
            grabOffsets: grabOffsets,
            hasMoved: false,
            lastPoint: point,
            lastShiftDown: NSEvent.modifierFlags.contains(.shift),
            lastRatios: ratios
        )

        switch hit {
        case .single(let seam):
            seamOverlay.showSeam(
                visualRectCG: seam.visualRect,
                axis: seam.axis,
                isDragging: true,
                primaryScreenHeight: displayObserver.primaryScreenHeight
            )
        case .intersection(let vs, let hs):
            seamOverlay.showIntersection(
                verticalVisualCG: unionVisualRect(of: vs),
                horizontalVisualCG: unionVisualRect(of: hs),
                isDragging: true,
                primaryScreenHeight: displayObserver.primaryScreenHeight
            )
        }
    }

    private func handleSeamDragMove(to point: CGPoint, shiftDown: Bool) {
        guard var session = seamDrag else { return }
        session.lastPoint = point
        session.lastShiftDown = shiftDown

        if !session.hasMoved {
            guard hypot(point.x - session.initialPoint.x, point.y - session.initialPoint.y) >= 1.5 else {
                seamDrag = session
                return
            }
            session.hasMoved = true
        }

        let tree = store.tree(for: session.hit.spaceKey)
        let allSeams = SeamGeometry.seams(in: tree, spaceKey: session.hit.spaceKey, bounds: session.screenBounds)

        switch session.hit {
        case .single(let seam):
            let update = SeamGeometry.dragUpdate(
                pointer: point,
                seam: seam,
                tree: tree,
                minSizes: store.learnedMinSizes,
                allSeams: allSeams,
                disableSnapping: shiftDown,
                grabOffset: session.grabOffsets[seam.splitID] ?? 0
            )
            let wasCollapsing = session.lastCollapseTarget != .none
            let isCollapsing = update.collapseTarget != .none
            if !wasCollapsing && isCollapsing {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            session.lastCollapseTarget = update.collapseTarget

            switch update.collapseTarget {
            case .collapseFirst(let expanded), .collapseSecond(let expanded):
                session.lastSnapKey = ""
                session.lastWasClamped = false
                seamDrag = session
                seamOverlay.showCollapsePreview(
                    expandedBoundsCG: expanded,
                    axis: seam.axis,
                    primaryScreenHeight: displayObserver.primaryScreenHeight
                )
                return

            case .none:
                let snapKey = Self.snapFeedbackKey(for: update.snapKind)
                if !snapKey.isEmpty && snapKey != session.lastSnapKey {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                session.lastSnapKey = snapKey

                if update.isClamped && !session.lastWasClamped {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
                session.lastWasClamped = update.isClamped

                seamOverlay.showSeam(
                    visualRectCG: update.visualRect,
                    axis: seam.axis,
                    isDragging: true,
                    isClamped: update.isClamped,
                    isSnapped: update.snapKind != .none,
                    primaryScreenHeight: displayObserver.primaryScreenHeight
                )
                let prevRatio = session.lastRatios[seam.splitID] ?? seam.ratio
                if abs(update.ratio - prevRatio) >= 0.001 {
                    session.lastRatios[seam.splitID] = update.ratio
                    seamDrag = session
                    let frames = store.updateSeamRatio(
                        spaceKey: seam.spaceKey,
                        splitID: seam.splitID,
                        ratio: update.ratio,
                        screenBounds: session.screenBounds
                    )
                    axBridge.enqueueLiveFrames(frames)
                } else {
                    seamDrag = session
                }
            }

        case .intersection(let initialVs, let initialHs):
            let vIDs = Set(initialVs.map(\.splitID))
            let hIDs = Set(initialHs.map(\.splitID))

            // Read live seams from the current tree so child splits' parentBounds reflect the
            // latest vertical/horizontal positions rather than stale drag-start bounds.
            let liveVs = allSeams.filter { vIDs.contains($0.splitID) }
            let liveHs = allSeams.filter { hIDs.contains($0.splitID) }

            var changed = false
            var anyClamped = false
            var snapParts: [String] = []

            let stationaryVSeams = allSeams.filter { !vIDs.contains($0.splitID) }
            for vSeam in liveVs {
                let vUpdate = SeamGeometry.dragUpdate(
                    pointer: point,
                    seam: vSeam,
                    tree: tree,
                    minSizes: store.learnedMinSizes,
                    allSeams: stationaryVSeams,
                    disableSnapping: shiftDown,
                    grabOffset: session.grabOffsets[vSeam.splitID] ?? 0
                )
                if vUpdate.isClamped { anyClamped = true }
                if vUpdate.snapKind != .none {
                    snapParts.append("v:\(vSeam.splitID):\(Self.snapFeedbackKey(for: vUpdate.snapKind))")
                }
                let prev = session.lastRatios[vSeam.splitID] ?? vSeam.ratio
                if abs(vUpdate.ratio - prev) >= 0.001 {
                    session.lastRatios[vSeam.splitID] = vUpdate.ratio
                    _ = store.updateSeamRatio(
                        spaceKey: vSeam.spaceKey,
                        splitID: vSeam.splitID,
                        ratio: vUpdate.ratio,
                        screenBounds: session.screenBounds
                    )
                    changed = true
                }
            }

            let treeAfterV = store.tree(for: session.hit.spaceKey)
            let seamsAfterV = SeamGeometry.seams(in: treeAfterV, spaceKey: session.hit.spaceKey, bounds: session.screenBounds)
            let stationaryHSeams = seamsAfterV.filter { !hIDs.contains($0.splitID) }
            for hSeam in liveHs {
                let hUpdate = SeamGeometry.dragUpdate(
                    pointer: point,
                    seam: hSeam,
                    tree: treeAfterV,
                    minSizes: store.learnedMinSizes,
                    allSeams: stationaryHSeams,
                    disableSnapping: shiftDown,
                    grabOffset: session.grabOffsets[hSeam.splitID] ?? 0
                )
                if hUpdate.isClamped { anyClamped = true }
                if hUpdate.snapKind != .none {
                    snapParts.append("h:\(hSeam.splitID):\(Self.snapFeedbackKey(for: hUpdate.snapKind))")
                }
                let prev = session.lastRatios[hSeam.splitID] ?? hSeam.ratio
                if abs(hUpdate.ratio - prev) >= 0.001 {
                    session.lastRatios[hSeam.splitID] = hUpdate.ratio
                    _ = store.updateSeamRatio(
                        spaceKey: hSeam.spaceKey,
                        splitID: hSeam.splitID,
                        ratio: hUpdate.ratio,
                        screenBounds: session.screenBounds
                    )
                    changed = true
                }
            }

            let snapKey = snapParts.joined(separator: "|")
            if !snapKey.isEmpty && snapKey != session.lastSnapKey {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            session.lastSnapKey = snapKey

            if anyClamped && !session.lastWasClamped {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            session.lastWasClamped = anyClamped
            seamDrag = session

            // Compute fresh visual hairlines from the updated tree so both lines track the cursor
            // and span the exact updated pane widths/heights.
            let updatedTree = store.tree(for: session.hit.spaceKey)
            let updatedSeams = SeamGeometry.seams(in: updatedTree, spaceKey: session.hit.spaceKey, bounds: session.screenBounds)
            let updatedVs = updatedSeams.filter { vIDs.contains($0.splitID) }
            let updatedHs = updatedSeams.filter { hIDs.contains($0.splitID) }
            seamOverlay.showIntersection(
                verticalVisualCG: unionVisualRect(of: updatedVs.isEmpty ? initialVs : updatedVs),
                horizontalVisualCG: unionVisualRect(of: updatedHs.isEmpty ? initialHs : updatedHs),
                isDragging: true,
                isClamped: anyClamped,
                isSnapped: !snapParts.isEmpty,
                primaryScreenHeight: displayObserver.primaryScreenHeight
            )
            if changed {
                let frames = store.frames(for: session.hit.spaceKey, screenBounds: session.screenBounds)
                axBridge.enqueueLiveFrames(frames)
            }
        }
    }

    private func handleSeamDragCancel() {
        guard let session = seamDrag else { return }
        seamDrag = nil
        seamOverlay.hide()

        let finalFrames = store.restoreSeamRatios(
            session.initialRatios,
            in: session.hit.spaceKey,
            screenBounds: session.screenBounds
        )
        axBridge.endLiveResizeBatch(finalFrames: finalFrames, involvedPIDs: session.involvedPIDs)
        refreshSeamsAndUI()
    }

    private func handleSeamDragEnd(at point: CGPoint) {
        guard let session = seamDrag else { return }
        seamDrag = nil
        seamOverlay.hide()

        guard session.hasMoved else {
            axBridge.endLiveResizeBatch(finalFrames: [:], involvedPIDs: session.involvedPIDs)
            return
        }

        let finalFrames: [WindowID: CGRect]
        switch session.hit {
        case .single(let seam):
            switch session.lastCollapseTarget {
            case .collapseFirst, .collapseSecond:
                finalFrames = store.collapseEmptySide(
                    spaceKey: seam.spaceKey,
                    splitID: seam.splitID,
                    screenBounds: session.screenBounds
                ) ?? store.frames(for: seam.spaceKey, screenBounds: session.screenBounds)
            case .none:
                finalFrames = store.frames(for: seam.spaceKey, screenBounds: session.screenBounds)
            }
        case .intersection:
            finalFrames = store.frames(for: session.hit.spaceKey, screenBounds: session.screenBounds)
        }

        axBridge.endLiveResizeBatch(finalFrames: finalFrames, involvedPIDs: session.involvedPIDs)
        refreshSeamsAndUI()

        // After apps settle, record any enforced minimum sizes via WindowServer readback
        // (never mid-drag, so transient lag can never poison clamping).
        let spaceKey = session.hit.spaceKey
        let expected = finalFrames
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, self.isRunning, self.seamDrag == nil else { return }
            self.learnSettledMinimumSizes(expected: expected, in: spaceKey)
        }
    }

    private func handleSeamDoubleClick(_ hit: SeamHit) {
        guard isRunning, let bounds = displayObserver.usableBounds(for: hit.spaceKey) else { return }
        seamOverlay.hide()

        var updated = false
        for seam in hit.allSeams {
            if store.doubleClickSeam(spaceKey: seam.spaceKey, splitID: seam.splitID, screenBounds: bounds) != nil {
                updated = true
            }
        }
        if updated {
            let frames = store.frames(for: hit.spaceKey, screenBounds: bounds)
            axBridge.applyFrames(frames, crossMonitorSafe: false)
            refreshSeamsAndUI()
        }
    }

    private func learnSettledMinimumSizes(expected: [WindowID: CGRect], in spaceKey: SpaceKey) {
        var learnedAny = false
        for (wid, target) in expected {
            guard store.spaceKey(for: wid) == spaceKey,
                  let actual = axBridge.windowBounds(windowID: wid) else {
                continue
            }
            var minW: CGFloat = 0
            var minH: CGFloat = 0
            if actual.width > target.width + 6 { minW = actual.width }
            if actual.height > target.height + 6 { minH = actual.height }
            if minW > 0 || minH > 0 {
                store.recordMinimumSize(CGSize(width: minW, height: minH), for: wid)
                learnedAny = true
                SeamstressLog.layout.debug("Learned settled min size for window \(wid): \(Int(minW))x\(Int(minH))")
            }
        }
        if learnedAny,
           let bounds = displayObserver.usableBounds(for: spaceKey),
           let updatedFrames = store.collapseImpossibleEmptySplits(in: spaceKey, screenBounds: bounds) {
            SeamstressLog.layout.info("Collapsed over-constrained empty split in \(spaceKey.description, privacy: .public)")
            axBridge.applyFrames(updatedFrames, crossMonitorSafe: false)
            refreshSeamsAndUI()
        }
    }

    private func unionVisualRect(of seams: [VisibleSeam]) -> CGRect {
        guard var rect = seams.first?.visualRect else { return .zero }
        for seam in seams.dropFirst() {
            rect = rect.union(seam.visualRect)
        }
        return rect
    }

    private func recordDeclaredMinSizeIfAvailable(for windowID: WindowID) {
        if let declared = SkyLightBridge.shared.declaredMinimumSize(for: windowID) {
            store.recordMinimumSize(declared, for: windowID)
        }
    }

    // MARK: - Window drag (normal detach, manual resize detach & Option / Ctrl+Cmd drag tiling)

    private func handleWindowMouseDown(at point: CGPoint, snapModifierDown: Bool, isGestureDrag: Bool) {
        guard isRunning else { return }
        seamOverlay.hide()
        dropOverlay.hide()
        inputTap.setHasActiveWindowMove(false)

        guard let top = axBridge.topWindow(at: point) else {
            windowDrag = nil
            return
        }

        windowDrag = WindowDragSession(
            window: top,
            pressPoint: point,
            preDragFrame: top.bounds,
            startedWithGestureDragModifier: isGestureDrag,
            phase: .pending,
            currentPlan: nil
        )
    }

    private func handleWindowMouseDragged(to point: CGPoint, snapModifierDown: Bool) {
        guard var session = windowDrag else { return }
        guard session.phase != .ignored else { return }

        if session.phase == .pending {
            let moved = hypot(point.x - session.pressPoint.x, point.y - session.pressPoint.y)
            guard moved >= 4 else { return }

            guard let liveBounds = axBridge.windowBounds(windowID: session.window.windowID) else {
                session.phase = .ignored
                windowDrag = session
                return
            }

            let dw = abs(liveBounds.width - session.window.bounds.width)
            let dh = abs(liveBounds.height - session.window.bounds.height)
            let isPotentialManualResize = !session.startedWithGestureDragModifier
                && session.window.bounds.isPointNearEdge(session.pressPoint)
            if isPotentialManualResize && (dw > 1.5 || dh > 1.5) {
                // Native window edge/corner resize: if the window was tiled, detach it cleanly
                // and expand neighbors so no stale phantom seam remains behind.
                if store.isTiled(session.window.windowID),
                   let space = store.detachByManualResize(windowID: session.window.windowID) {
                    SeamstressLog.layout.info("Detached window \(session.window.windowID) on manual edge resize")
                    applyFramesIfActive(spaces: [space])
                    refreshSeamsAndUI()
                }
                session.phase = .ignored
                windowDrag = session
                return
            }

            let dx = abs(liveBounds.origin.x - session.window.bounds.origin.x)
            let dy = abs(liveBounds.origin.y - session.window.bounds.origin.y)
            guard dx >= 2 || dy >= 2 else {
                // Likely text selection or dragging content inside the window.
                return
            }

            // Confirmed window move! Verify it's a standard resizable window once.
            guard axBridge.isStandardTileableWindow(windowID: session.window.windowID, pid: session.window.ownerPID) else {
                session.phase = .ignored
                windowDrag = session
                return
            }

            axBridge.register(windowID: session.window.windowID, pid: session.window.ownerPID)
            recordDeclaredMinSizeIfAvailable(for: session.window.windowID)
            session.phase = .moving
            inputTap.setHasActiveWindowMove(true)

            // Dragging a tiled window WITHOUT a snap modifier detaches it immediately and expands neighbors,
            // while keeping a short undo snapshot in case Option or Ctrl+Cmd is pressed right after starting.
            if !snapModifierDown && store.isTiled(session.window.windowID) {
                session.detachUndo = detachTiledWindowDuringDrag(
                    windowID: session.window.windowID,
                    currentFrame: liveBounds,
                    cursor: point
                )
                session.detachedAt = ProcessInfo.processInfo.systemUptime
            }
        }

        if snapModifierDown {
            let previousAction = session.currentPlan?.action
            let plan = computeDropPlan(at: point, draggedWindowID: session.window.windowID)
            session.currentPlan = plan
            windowDrag = session
            if let plan {
                if plan.action != previousAction {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                dropOverlay.show(
                    cgRect: plan.previewRect,
                    kind: plan.previewKind,
                    primaryScreenHeight: displayObserver.primaryScreenHeight
                )
            } else {
                dropOverlay.hide(animated: true)
            }
        } else {
            session.currentPlan = nil
            windowDrag = session
            dropOverlay.hide(animated: true)
        }
    }

    private func handleSnapModifierChangedDuringDrag(snapModifierDown: Bool, point: CGPoint) {
        guard var session = windowDrag, session.phase == .moving else { return }

        if snapModifierDown {
            // Late-modifier grace window: if the user started dragging a tiled window and pressed
            // Option (or Ctrl+Cmd) within 0.45s, restore its pre-detach layout so center-swap & T-splits work seamlessly.
            if let undo = session.detachUndo,
               let detachedAt = session.detachedAt,
               ProcessInfo.processInfo.systemUptime - detachedAt <= Self.lateOptionGraceWindow {
                if store.restoreDetachSnapshot(undo) {
                    session.detachUndo = nil
                    session.detachedAt = nil
                    applyFramesIfActive(spaces: [undo.spaceKey], excluding: session.window.windowID)
                    refreshSeamsAndUI()
                }
            }

            let previousAction = session.currentPlan?.action
            let plan = computeDropPlan(at: point, draggedWindowID: session.window.windowID)
            session.currentPlan = plan
            windowDrag = session
            if let plan {
                if plan.action != previousAction {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                dropOverlay.show(
                    cgRect: plan.previewRect,
                    kind: plan.previewKind,
                    primaryScreenHeight: displayObserver.primaryScreenHeight
                )
            } else {
                dropOverlay.hide(animated: true)
            }
        } else {
            session.currentPlan = nil
            windowDrag = session
            dropOverlay.hide(animated: true)

            // If user started dragging a tiled window with a snap modifier held and then released it
            // mid-drag, detach it to floating right away.
            if store.isTiled(session.window.windowID) {
                let current = axBridge.windowBounds(windowID: session.window.windowID) ?? session.preDragFrame
                session.detachUndo = detachTiledWindowDuringDrag(
                    windowID: session.window.windowID,
                    currentFrame: current,
                    cursor: point
                )
                session.detachedAt = ProcessInfo.processInfo.systemUptime
                windowDrag = session
            }
        }
    }

    private func handleWindowDragCancel() {
        guard let session = windowDrag else { return }
        windowDrag = nil
        dropOverlay.hide(animated: true)
        inputTap.setHasActiveWindowMove(false)

        var framesToRestore: [WindowID: CGRect] = [:]
        if let undo = session.detachUndo {
            if store.restoreDetachSnapshot(undo) {
                persistSavedFloatingFrames()
                if let bounds = displayObserver.usableBounds(for: undo.spaceKey) {
                    framesToRestore = store.frames(for: undo.spaceKey, screenBounds: bounds)
                }
            }
        } else if let space = store.spaceKey(for: session.window.windowID),
                  let bounds = displayObserver.usableBounds(for: space),
                  let rect = store.frames(for: space, screenBounds: bounds)[session.window.windowID] {
            framesToRestore = [session.window.windowID: rect]
        } else {
            framesToRestore = [session.window.windowID: session.preDragFrame]
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        if !framesToRestore.isEmpty {
            let expected = framesToRestore
            axBridge.applyFrames(expected, crossMonitorSafe: true) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    guard let self, self.isRunning, self.windowDrag == nil, self.seamDrag == nil else { return }
                    var drifted: [WindowID: CGRect] = [:]
                    for (wid, target) in expected {
                        if let actual = self.axBridge.windowBounds(windowID: wid) {
                            let drift = abs(actual.origin.x - target.origin.x)
                                + abs(actual.origin.y - target.origin.y)
                                + abs(actual.width - target.width)
                                + abs(actual.height - target.height)
                            if drift > 3 {
                                drifted[wid] = target
                            }
                        }
                    }
                    if !drifted.isEmpty {
                        self.axBridge.applyFrames(drifted, crossMonitorSafe: true)
                    }
                }
            }
        }

        refreshSeamsAndUI()
    }

    private func handleWindowMouseUp(at point: CGPoint, snapModifierDown: Bool) {
        dropOverlay.hide(animated: true)
        inputTap.setHasActiveWindowMove(false)
        guard let session = windowDrag else { return }
        windowDrag = nil

        guard session.phase == .moving, snapModifierDown else { return }

        let plan = computeDropPlan(at: point, draggedWindowID: session.window.windowID) ?? session.currentPlan
        guard let plan else { return }

        let commit = store.commitDrop(
            plan,
            draggedWindowID: session.window.windowID,
            preDragFrame: session.preDragFrame,
            boundsForSpace: { [weak self] spaceKey in
                self?.displayObserver.usableBounds(for: spaceKey)
            }
        )
        persistSavedFloatingFrames()

        recordDeclaredMinSizeIfAvailable(for: session.window.windowID)
        SeamstressLog.layout.info("Committed drop for window \(session.window.windowID) into \(plan.targetSpace.description, privacy: .public)")

        var allFrames = commit.framesToApply
        for (wid, restored) in commit.detachedWindows {
            allFrames[wid] = restored
        }

        let draggedID = session.window.windowID
        let targetForDragged = commit.framesToApply[draggedID]
        let needsMultiWindowVerify = commit.affectedSpaces.count > 1 || !commit.detachedWindows.isEmpty
        let detachedIDs = Set(commit.detachedWindows.keys)
        let expectedAll = allFrames

        let targetSpace = plan.targetSpace
        let expectedTargetFrames = commit.framesToApply

        // Apply immediately, then verify once after macOS finishes its native mouse-up tracking.
        axBridge.applyFrames(allFrames, crossMonitorSafe: true) { [weak self] in
            guard let self else { return }
            if let expected = targetForDragged {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    guard let self, self.isRunning, self.store.isTiled(draggedID) else { return }
                    if let actual = self.axBridge.windowBounds(windowID: draggedID) {
                        let drift = abs(actual.origin.x - expected.origin.x)
                            + abs(actual.origin.y - expected.origin.y)
                            + abs(actual.width - expected.width)
                            + abs(actual.height - expected.height)
                        if drift > 3 {
                            self.axBridge.applyFrames([draggedID: expected], crossMonitorSafe: true)
                        }
                    }
                }
            }
            if needsMultiWindowVerify {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
                    guard let self, self.isRunning, self.windowDrag == nil, self.seamDrag == nil else { return }
                    var drifted: [WindowID: CGRect] = [:]
                    for (wid, expected) in expectedAll {
                        guard self.store.isTiled(wid) || detachedIDs.contains(wid),
                              let actual = self.axBridge.windowBounds(windowID: wid) else {
                            continue
                        }
                        let drift = abs(actual.origin.x - expected.origin.x)
                            + abs(actual.origin.y - expected.origin.y)
                            + abs(actual.width - expected.width)
                            + abs(actual.height - expected.height)
                        if drift > 3 {
                            drifted[wid] = expected
                        }
                    }
                    if !drifted.isEmpty {
                        self.axBridge.applyFrames(drifted, crossMonitorSafe: true)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                guard let self, self.isRunning, self.windowDrag == nil, self.seamDrag == nil else { return }
                self.learnSettledMinimumSizes(expected: expectedTargetFrames, in: targetSpace)
            }
        }

        refreshSeamsAndUI()
    }

    @discardableResult
    private func detachTiledWindowDuringDrag(
        windowID: WindowID,
        currentFrame: CGRect,
        cursor: CGPoint
    ) -> DetachUndoSnapshot? {
        let existingSpace = store.spaceKey(for: windowID)
        let existingBounds = existingSpace.flatMap { displayObserver.usableBounds(for: $0) }
        guard let detached = store.detachByUserDrag(
            windowID: windowID,
            currentFrame: currentFrame,
            cursor: cursor,
            screenBounds: existingBounds
        ) else {
            return nil
        }
        persistSavedFloatingFrames()
        var framesToApply: [WindowID: CGRect] = [:]
        if let bounds = displayObserver.usableBounds(for: detached.spaceKey) {
            for (wid, rect) in store.frames(for: detached.spaceKey, screenBounds: bounds) {
                framesToApply[wid] = rect
            }
        }
        if let restored = detached.restoredFrame {
            framesToApply[windowID] = restored
        }
        if !framesToApply.isEmpty {
            axBridge.applyFrames(framesToApply, crossMonitorSafe: false)
        }
        refreshSeamsAndUI()
        return detached.undo
    }

    private func computeDropPlan(at point: CGPoint, draggedWindowID: WindowID) -> DropPlan? {
        guard let display = displayObserver.display(containing: point) else { return nil }
        return store.planDrop(
            pointer: point,
            draggedWindowID: draggedWindowID,
            targetSpace: display.spaceKey,
            screenBounds: display.usableFrameCG
        )
    }

    // MARK: - Maintenance & UI sync

    private func suppressSanitySweepForWakeGrace() {
        let target = ProcessInfo.processInfo.systemUptime + Self.postWakeSweepGrace
        if target > sanitySweepSuppressedUntil {
            sanitySweepSuppressedUntil = target
        }
    }

    /// Debounce topology re-apply after wake or monitor plug/unplug bursts (~0.6s settle).
    private func scheduleDebouncedTopologyReapply() {
        pendingTopologyReapply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            guard !self.displayObserver.isSessionInactive else { return }
            _ = self.displayObserver.refresh()
            self.reapplyActiveSpaces()
            self.adoptExistingLayoutsIfNeeded()
            self.refreshSeamsAndUI()
        }
        pendingTopologyReapply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// On launch (and the first time each native Space is visited after launch), inspect
    /// existing on-screen window geometry and adopt close flush-tiled matches into the BSP
    /// store without moving or jittering any windows.
    private func adoptExistingLayoutsIfNeeded() {
        // Never probe while the screen is locked or displays are asleep — otherwise spaces
        // would be permanently marked probed while windows are off-screen/unavailable.
        guard !displayObserver.isSessionInactive else { return }

        let displays = displayObserver.displays
        let unprobed = displays.filter {
            !displayObserver.isDisplayAsleep($0.displayID) &&
            !probedSpaces.contains($0.spaceKey) &&
            store.tree(for: $0.spaceKey).isEmpty
        }
        guard !unprobed.isEmpty else { return }

        let onScreen = axBridge.onScreenNormalWindows()
        guard !onScreen.isEmpty else { return }
        let snapByID = Dictionary(uniqueKeysWithValues: onScreen.map { ($0.windowID, $0) })

        var needsRetry = false
        for display in unprobed {
            let spaceKey = display.spaceKey

            let usable = display.usableFrameCG
            let full = display.fullFrameCG
            let candidates: [WindowCandidate] = onScreen.compactMap { snap in
                guard !store.isTiled(snap.windowID) else { return nil }
                // Skip native macOS fullscreen windows covering the menu bar
                if full.height > usable.height + 10,
                   abs(snap.bounds.width - full.width) <= 2,
                   abs(snap.bounds.height - full.height) <= 2 {
                    return nil
                }
                let center = CGPoint(x: snap.bounds.midX, y: snap.bounds.midY)
                guard usable.contains(center) else { return nil }
                return WindowCandidate(windowID: snap.windowID, frame: snap.bounds)
            }

            guard let reconstructed = LayoutReconstructor.reconstruct(windows: candidates, in: usable) else {
                probedSpaces.insert(spaceKey)
                continue
            }

            let matchedIDs = reconstructed.allWindowIDs
            var sawTransientFailure = false
            var sawNonStandard = false
            for wid in matchedIDs {
                guard let snap = snapByID[wid] else {
                    sawTransientFailure = true
                    break
                }
                switch axBridge.checkTileability(windowID: wid, pid: snap.ownerPID, timeout: 0.6) {
                case .tileable:
                    break
                case .nonStandard:
                    SeamstressLog.layout.info("Skipped adoption in \(spaceKey.description, privacy: .public): window \(wid) (\(snap.ownerName ?? "?", privacy: .public)) is non-standard")
                    sawNonStandard = true
                case .unavailable:
                    SeamstressLog.layout.info("Deferring adoption in \(spaceKey.description, privacy: .public): AX unavailable/timed out for window \(wid) (\(snap.ownerName ?? "?", privacy: .public))")
                    sawTransientFailure = true
                }
                if sawNonStandard || sawTransientFailure { break }
            }

            if sawTransientFailure {
                // Don't permanently mark this Space probed when an app momentarily timed out on AX.
                needsRetry = true
                continue
            }
            probedSpaces.insert(spaceKey)
            guard !sawNonStandard else { continue }

            let adopted = store.adoptReconstructedTree(reconstructed, for: spaceKey)
            for wid in adopted {
                if let snap = snapByID[wid] {
                    axBridge.register(windowID: wid, pid: snap.ownerPID)
                }
                recordDeclaredMinSizeIfAvailable(for: wid)
            }
            if !adopted.isEmpty {
                SeamstressLog.layout.notice("Adopted \(adopted.count) existing tiled window(s) in \(spaceKey.description, privacy: .public)")
            }
        }

        if needsRetry, adoptionRetryCount < 3 {
            adoptionRetryCount += 1
            pendingAdoptionRetry?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning else { return }
                self.adoptExistingLayoutsIfNeeded()
                self.refreshSeamsAndUI()
            }
            pendingAdoptionRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    private func reapplyActiveSpaces() {
        var frames: [WindowID: CGRect] = [:]
        for entry in displayObserver.activeSpaces() {
            for (wid, rect) in store.frames(for: entry.spaceKey, screenBounds: entry.bounds) {
                frames[wid] = rect
            }
        }
        if !frames.isEmpty {
            axBridge.applyFrames(frames, crossMonitorSafe: true)
        }
    }

    /// Lightweight WindowServer-only sweep (zero AX IPC): clears tiled windows on active Spaces
    /// that closed, minimized, hid, or entered native macOS fullscreen without sending an AX event.
    private func runSanitySweep() {
        guard isRunning, seamDrag == nil, windowDrag == nil else { return }
        guard !displayObserver.isSessionInactive else { return }
        guard ProcessInfo.processInfo.systemUptime >= sanitySweepSuppressedUntil else { return }

        let awakeSpaces = displayObserver.displays.filter { !displayObserver.isDisplayAsleep($0.displayID) }
        guard !awakeSpaces.isEmpty else { return }

        let activeSpaceKeys = Set(awakeSpaces.map(\.spaceKey))
        let tiledOnActiveSpaces = store.allTiledWindowIDs.filter { wid in
            guard let key = store.spaceKey(for: wid) else { return false }
            return activeSpaceKeys.contains(key)
        }
        guard !tiledOnActiveSpaces.isEmpty else { return }

        let onScreenList = axBridge.onScreenNormalWindows()
        // During transient lock/sleep/reconfiguration states, WindowServer can momentarily
        // report zero on-screen normal windows; never wipe layouts on an empty snapshot.
        guard !onScreenList.isEmpty else { return }

        let onScreen = Dictionary(uniqueKeysWithValues: onScreenList.map { ($0.windowID, $0) })

        var affectedSpaces: Set<SpaceKey> = []
        for wid in tiledOnActiveSpaces {
            guard let snap = onScreen[wid] else {
                if let space = store.handleWindowUnavailable(wid) {
                    SeamstressLog.layout.info("Sanity sweep cleared off-screen window \(wid) in \(space.description, privacy: .public)")
                    affectedSpaces.insert(space)
                }
                axBridge.forget(windowID: wid)
                continue
            }
            // Detect native macOS fullscreen (window covers full screen including menu bar)
            if let key = store.spaceKey(for: wid),
               let display = displayObserver.display(for: key),
               abs(snap.bounds.width - display.fullFrameCG.width) <= 2,
               abs(snap.bounds.height - display.fullFrameCG.height) <= 2,
               display.fullFrameCG.height > display.usableFrameCG.height + 10 {
                if let space = store.handleWindowUnavailable(wid) {
                    SeamstressLog.layout.info("Sanity sweep cleared fullscreen window \(wid) in \(space.description, privacy: .public)")
                    affectedSpaces.insert(space)
                }
                axBridge.forget(windowID: wid)
            }
        }

        if !affectedSpaces.isEmpty {
            applyFramesIfActive(spaces: affectedSpaces)
            refreshSeamsAndUI()
        }
    }

    private func applyFramesIfActive(spaces: Set<SpaceKey>, excluding excludedID: WindowID? = nil) {
        var frames: [WindowID: CGRect] = [:]
        for space in spaces {
            guard let bounds = displayObserver.usableBounds(for: space) else { continue }
            for (wid, rect) in store.frames(for: space, screenBounds: bounds) where wid != excludedID {
                frames[wid] = rect
            }
        }
        if !frames.isEmpty {
            axBridge.applyFrames(frames, crossMonitorSafe: false)
        }
    }

    private func refreshSeamsAndUI() {
        let active = displayObserver.activeSpaces()
        let seams = store.visibleSeams(for: active)
        inputTap.updateVisibleSeams(seams)

        // Sync AXObserver PIDs and EventTap tiled state to apps that currently have tiled windows
        let tiledIDs = store.allTiledWindowIDs
        var pids: Set<pid_t> = []
        for wid in tiledIDs {
            if let pid = axBridge.pid(for: wid) {
                pids.insert(pid)
            }
        }
        inputTap.updateTiledState(windowIDs: tiledIDs, pids: pids)
        eventMonitor.syncObservedPIDs(pids)

        updateMenuState()
    }

    private func updateMenuState() {
        tiledWindowCount = store.allTiledWindowIDs.count
        if let display = currentMenuDisplay() {
            let tree = store.tree(for: display.spaceKey)
            activeDisplayBounds = display.usableFrameCG
            activeDisplayName = display.localizedName
            activeLayoutLeaves = tree.leafPlacements(in: display.usableFrameCG)
            canEqualizeCurrentSpace = Self.hasUnequalSplit(in: tree.root)
        } else {
            activeDisplayBounds = .zero
            activeDisplayName = ""
            activeLayoutLeaves = []
            canEqualizeCurrentSpace = false
        }
    }

    private static func hasUnequalSplit(in node: LayoutTree.Node) -> Bool {
        switch node {
        case .empty, .window:
            return false
        case .split(_, _, let ratio, let first, let second):
            if abs(ratio - 0.5) > 0.005 {
                return true
            }
            return hasUnequalSplit(in: first) || hasUnequalSplit(in: second)
        }
    }

    private static func snapFeedbackKey(for kind: SeamSnapKind) -> String {
        switch kind {
        case .none:
            return ""
        case .detent(let ratio):
            return "detent:\(Int((ratio * 1000).rounded()))"
        case .alignedSeam(let pos):
            return "align:\(Int(pos.rounded()))"
        }
    }

    private func loadSavedFloatingFrames() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.savedFloatingFramesDefaultsKey) as? [String: [Double]],
              !stored.isEmpty else {
            return
        }
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        var liveWindowIDs: Set<WindowID> = []
        liveWindowIDs.reserveCapacity(list.count)
        for entry in list {
            if let wid = entry[kCGWindowNumber as String] as? UInt32 {
                liveWindowIDs.insert(wid)
            }
        }

        var restored: [WindowID: CGRect] = [:]
        for (key, coords) in stored {
            guard let wid = WindowID(key),
                  liveWindowIDs.contains(wid),
                  coords.count == 4,
                  coords.allSatisfy(\.isFinite),
                  coords[2] > 0,
                  coords[3] > 0 else {
                continue
            }
            restored[wid] = CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3])
        }
        if !restored.isEmpty {
            store.restoreSavedFloatingFrames(restored)
        }
    }

    private func persistSavedFloatingFrames() {
        let snapshot = store.savedFloatingFramesSnapshot()
        if snapshot.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.savedFloatingFramesDefaultsKey)
            return
        }
        var encoded: [String: [Double]] = [:]
        encoded.reserveCapacity(min(snapshot.count, Self.maxPersistedFloatingFrames))
        for (wid, rect) in snapshot.prefix(Self.maxPersistedFloatingFrames) {
            encoded[String(wid)] = [
                Double(rect.origin.x),
                Double(rect.origin.y),
                Double(rect.size.width),
                Double(rect.size.height),
            ]
        }
        UserDefaults.standard.set(encoded, forKey: Self.savedFloatingFramesDefaultsKey)
    }

    private func currentMenuDisplay() -> DisplayInfo? {
        let mouseNS = NSEvent.mouseLocation
        let mouseCG = CoordinateSpace.flipY(mouseNS, primaryHeight: displayObserver.primaryScreenHeight)
        return displayObserver.display(containing: mouseCG) ?? displayObserver.displays.first
    }
}
