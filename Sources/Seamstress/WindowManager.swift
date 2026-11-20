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
    @Published private(set) var tiledWindowCount: Int = 0

    private let displayObserver = DisplayObserver()
    private let store = SpaceLayoutStore()
    private let axBridge = AXWindowBridge()
    private let eventMonitor = WindowEventMonitor()
    private let inputTap = InputEventTap()
    private let dropOverlay = DropPreviewOverlay()
    private let seamOverlay = SeamHighlightOverlay()

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
        var phase: Phase = .pending
        var currentPlan: DropPlan?
    }

    private struct SeamDragSession {
        let seam: VisibleSeam
        let screenBounds: CGRect
        let involvedPIDs: Set<pid_t>
        var lastRatio: CGFloat
        var lastCollapseTarget: SeamCollapseTarget = .none
    }

    private var windowDrag: WindowDragSession?
    private var seamDrag: SeamDragSession?
    /// Spaces already probed for existing tiled layouts since launch (so manually cleared
    /// Spaces are never re-adopted on later Space switches).
    private var probedSpaces: Set<SpaceKey> = []

    init() {
        wireCallbacks()
    }

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else { return }

        SkyLightBridge.shared.enableBackgroundCursor()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXWindowBridge.axTimeout)

        displayObserver.refresh()
        displayObserver.startObserving()
        eventMonitor.start()

        guard inputTap.start() else {
            displayObserver.stopObserving()
            eventMonitor.stop()
            return
        }

        isRunning = true
        adoptExistingLayoutsIfNeeded()
        refreshSeamsAndUI()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        inputTap.stop()
        eventMonitor.stop()
        displayObserver.stopObserving()
        dropOverlay.hide()
        seamOverlay.hide()
        windowDrag = nil
        seamDrag = nil
    }

    /// Clear all tiled slots on the display under the mouse (or primary display).
    func resetCurrentSpaceLayout() {
        guard let display = currentMenuDisplay() else { return }
        let space = display.spaceKey
        let wids = store.tree(for: space).allWindowIDs
        for wid in wids {
            _ = store.handleWindowUnavailable(wid)
        }
        refreshSeamsAndUI()
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        displayObserver.onDisplaysOrSpacesChanged = { [weak self] topologyChanged in
            guard let self, self.isRunning else { return }
            self.dropOverlay.hide()
            self.seamOverlay.hide()
            self.windowDrag = nil
            self.seamDrag = nil

            if topologyChanged {
                self.reapplyActiveSpaces()
            } else {
                self.adoptExistingLayoutsIfNeeded()
            }
            self.refreshSeamsAndUI()
        }

        eventMonitor.onWindowBecameUnavailable = { [weak self] wid in
            guard let self, self.isRunning else { return }
            if let space = self.store.handleWindowUnavailable(wid) {
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
                self.applyFramesIfActive(spaces: affectedSpaces)
                self.refreshSeamsAndUI()
            }
        }

        eventMonitor.onSanitySweep = { [weak self] in
            self?.runSanitySweep()
        }

        inputTap.onHoverCandidateChanged = { [weak self] seam, point in
            self?.handleHoverCandidate(seam, at: point)
        }

        inputTap.isSeamUnoccludedSync = { [weak self] seam, point in
            guard let self else { return false }
            return !self.axBridge.isSeamPointOccluded(point, allowedWindowIDs: seam.participatingWindowIDs)
        }

        inputTap.onSeamDragBegin = { [weak self] seam, point in
            self?.handleSeamDragBegin(seam, at: point)
        }

        inputTap.onSeamDragMove = { [weak self] _, point in
            self?.handleSeamDragMove(to: point)
        }

        inputTap.onSeamDragEnd = { [weak self] _, point in
            self?.handleSeamDragEnd(at: point)
        }

        inputTap.onSeamDoubleClick = { [weak self] seam in
            self?.handleSeamDoubleClick(seam)
        }

        inputTap.onWindowMouseDown = { [weak self] point, optionDown in
            self?.handleWindowMouseDown(at: point, optionDown: optionDown)
        }

        inputTap.onWindowMouseDragged = { [weak self] point, optionDown in
            self?.handleWindowMouseDragged(to: point, optionDown: optionDown)
        }

        inputTap.onWindowMouseUp = { [weak self] point, optionDown in
            self?.handleWindowMouseUp(at: point, optionDown: optionDown)
        }

        inputTap.onOptionFlagChangedDuringDrag = { [weak self] optionDown, point in
            self?.handleOptionChangedDuringDrag(optionDown: optionDown, point: point)
        }
    }

    // MARK: - Seam hover, drag & double-click

    private func handleHoverCandidate(_ seam: VisibleSeam?, at point: CGPoint) {
        guard isRunning, seamDrag == nil, windowDrag == nil else {
            inputTap.setUnoccludedHoverSeam(nil)
            seamOverlay.hide()
            return
        }

        guard let seam else {
            inputTap.setUnoccludedHoverSeam(nil)
            seamOverlay.hide()
            return
        }

        // Verify no floating window sits on top of the seam at `point`.
        if axBridge.isSeamPointOccluded(point, allowedWindowIDs: seam.participatingWindowIDs) {
            inputTap.setUnoccludedHoverSeam(nil)
            seamOverlay.hide()
            return
        }

        inputTap.setUnoccludedHoverSeam(seam)
        seamOverlay.showSeam(
            visualRectCG: seam.visualRect,
            axis: seam.axis,
            isDragging: false,
            primaryScreenHeight: displayObserver.primaryScreenHeight
        )
    }

    private func handleSeamDragBegin(_ seam: VisibleSeam, at point: CGPoint) {
        guard isRunning, let bounds = displayObserver.usableBounds(for: seam.spaceKey) else { return }

        // Resolve PIDs of all participating windows and disable AXEnhancedUserInterface for the drag.
        var pids: Set<pid_t> = []
        for wid in seam.participatingWindowIDs {
            if let pid = axBridge.pid(for: wid) {
                pids.insert(pid)
            }
        }
        axBridge.beginLiveResizeBatch(pids: pids)

        seamDrag = SeamDragSession(
            seam: seam,
            screenBounds: bounds,
            involvedPIDs: pids,
            lastRatio: seam.ratio
        )
        seamOverlay.showSeam(
            visualRectCG: seam.visualRect,
            axis: seam.axis,
            isDragging: true,
            primaryScreenHeight: displayObserver.primaryScreenHeight
        )
        handleSeamDragMove(to: point)
    }

    private func handleSeamDragMove(to point: CGPoint) {
        guard var session = seamDrag else { return }
        let tree = store.tree(for: session.seam.spaceKey)
        let update = SeamGeometry.dragUpdate(
            pointer: point,
            seam: session.seam,
            tree: tree,
            minSizes: store.learnedMinSizes
        )

        session.lastCollapseTarget = update.collapseTarget

        switch update.collapseTarget {
        case .collapseFirst(let expanded), .collapseSecond(let expanded):
            seamDrag = session
            seamOverlay.showCollapsePreview(
                expandedBoundsCG: expanded,
                axis: session.seam.axis,
                primaryScreenHeight: displayObserver.primaryScreenHeight
            )
            return

        case .none:
            seamOverlay.showSeam(
                visualRectCG: update.visualRect,
                axis: session.seam.axis,
                isDragging: true,
                primaryScreenHeight: displayObserver.primaryScreenHeight
            )

            // Only push AX updates if the split ratio actually moved meaningfully.
            if abs(update.ratio - session.lastRatio) >= 0.001 {
                session.lastRatio = update.ratio
                seamDrag = session
                let frames = store.updateSeamRatio(
                    spaceKey: session.seam.spaceKey,
                    splitID: session.seam.splitID,
                    ratio: update.ratio,
                    screenBounds: session.screenBounds
                )
                axBridge.enqueueLiveFrames(frames)
            } else {
                seamDrag = session
            }
        }
    }

    private func handleSeamDragEnd(at point: CGPoint) {
        guard let session = seamDrag else { return }
        seamDrag = nil
        seamOverlay.hide()

        let finalFrames: [WindowID: CGRect]
        switch session.lastCollapseTarget {
        case .collapseFirst, .collapseSecond:
            finalFrames = store.collapseEmptySide(
                spaceKey: session.seam.spaceKey,
                splitID: session.seam.splitID,
                screenBounds: session.screenBounds
            ) ?? store.frames(for: session.seam.spaceKey, screenBounds: session.screenBounds)
        case .none:
            finalFrames = store.frames(for: session.seam.spaceKey, screenBounds: session.screenBounds)
        }

        axBridge.endLiveResizeBatch(finalFrames: finalFrames, involvedPIDs: session.involvedPIDs)
        refreshSeamsAndUI()
    }

    private func handleSeamDoubleClick(_ seam: VisibleSeam) {
        guard isRunning, let bounds = displayObserver.usableBounds(for: seam.spaceKey) else { return }
        seamOverlay.hide()
        if let frames = store.doubleClickSeam(spaceKey: seam.spaceKey, splitID: seam.splitID, screenBounds: bounds) {
            axBridge.applyFrames(frames, crossMonitorSafe: false)
            refreshSeamsAndUI()
        }
    }

    // MARK: - Window drag (normal detach & Option-drag tiling)

    private func handleWindowMouseDown(at point: CGPoint, optionDown: Bool) {
        guard isRunning else { return }
        seamOverlay.hide()
        dropOverlay.hide()

        guard let top = axBridge.topWindow(at: point) else {
            windowDrag = nil
            return
        }

        windowDrag = WindowDragSession(
            window: top,
            pressPoint: point,
            preDragFrame: top.bounds,
            phase: .pending,
            currentPlan: nil
        )
    }

    private func handleWindowMouseDragged(to point: CGPoint, optionDown: Bool) {
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
            if dw > 1.5 || dh > 1.5 {
                // Native window edge/corner resize, not a move.
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
            session.phase = .moving

            // Dragging a tiled window WITHOUT Option detaches it immediately and restores its floating size.
            if !optionDown && store.isTiled(session.window.windowID) {
                detachTiledWindowDuringDrag(
                    windowID: session.window.windowID,
                    currentFrame: liveBounds,
                    cursor: point
                )
            }
        }

        if optionDown {
            let plan = computeDropPlan(at: point, draggedWindowID: session.window.windowID)
            session.currentPlan = plan
            windowDrag = session
            if let plan {
                dropOverlay.show(
                    cgRect: plan.previewRect,
                    kind: plan.previewKind,
                    primaryScreenHeight: displayObserver.primaryScreenHeight
                )
            } else {
                dropOverlay.hide()
            }
        } else {
            session.currentPlan = nil
            windowDrag = session
            dropOverlay.hide()
        }
    }

    private func handleOptionChangedDuringDrag(optionDown: Bool, point: CGPoint) {
        guard var session = windowDrag, session.phase == .moving else { return }

        if optionDown {
            let plan = computeDropPlan(at: point, draggedWindowID: session.window.windowID)
            session.currentPlan = plan
            windowDrag = session
            if let plan {
                dropOverlay.show(
                    cgRect: plan.previewRect,
                    kind: plan.previewKind,
                    primaryScreenHeight: displayObserver.primaryScreenHeight
                )
            }
        } else {
            session.currentPlan = nil
            windowDrag = session
            dropOverlay.hide()

            // If user started dragging a tiled window with Option held and then released Option
            // mid-drag, detach it to floating right away.
            if store.isTiled(session.window.windowID) {
                let current = axBridge.windowBounds(windowID: session.window.windowID) ?? session.preDragFrame
                detachTiledWindowDuringDrag(
                    windowID: session.window.windowID,
                    currentFrame: current,
                    cursor: point
                )
            }
        }
    }

    private func handleWindowMouseUp(at point: CGPoint, optionDown: Bool) {
        dropOverlay.hide()
        guard let session = windowDrag else { return }
        windowDrag = nil

        guard session.phase == .moving, optionDown else { return }

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

        var allFrames = commit.framesToApply
        for (wid, restored) in commit.detachedWindows {
            allFrames[wid] = restored
        }

        let draggedID = session.window.windowID
        let targetForDragged = commit.framesToApply[draggedID]

        // Apply immediately, then verify once after macOS finishes its native mouse-up tracking.
        axBridge.applyFrames(allFrames, crossMonitorSafe: true) { [weak self] in
            guard let self, let expected = targetForDragged else { return }
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

        refreshSeamsAndUI()
    }

    private func detachTiledWindowDuringDrag(windowID: WindowID, currentFrame: CGRect, cursor: CGPoint) {
        guard let detached = store.detachByUserDrag(windowID: windowID, currentFrame: currentFrame, cursor: cursor) else {
            return
        }
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

    /// On launch (and the first time each native Space is visited after launch), inspect
    /// existing on-screen window geometry and adopt close flush-tiled matches into the BSP
    /// store without moving or jittering any windows.
    private func adoptExistingLayoutsIfNeeded() {
        let displays = displayObserver.displays
        let unprobed = displays.filter { !probedSpaces.contains($0.spaceKey) && store.tree(for: $0.spaceKey).isEmpty }
        guard !unprobed.isEmpty else { return }

        let onScreen = axBridge.onScreenNormalWindows()
        let snapByID = Dictionary(uniqueKeysWithValues: onScreen.map { ($0.windowID, $0) })

        for display in unprobed {
            let spaceKey = display.spaceKey
            probedSpaces.insert(spaceKey)

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
                continue
            }

            // Confirm matched windows are standard resizable windows before adopting.
            let matchedIDs = reconstructed.allWindowIDs
            let allTileable = matchedIDs.allSatisfy { wid in
                guard let snap = snapByID[wid] else { return false }
                return axBridge.isStandardTileableWindow(windowID: wid, pid: snap.ownerPID)
            }
            guard allTileable else { continue }

            let adopted = store.adoptReconstructedTree(reconstructed, for: spaceKey)
            for wid in adopted {
                if let snap = snapByID[wid] {
                    axBridge.register(windowID: wid, pid: snap.ownerPID)
                }
            }
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
        let activeSpaces = displayObserver.activeSpaces()
        guard !activeSpaces.isEmpty else { return }

        let activeSpaceKeys = Set(activeSpaces.map(\.spaceKey))
        let tiledOnActiveSpaces = store.allTiledWindowIDs.filter { wid in
            guard let key = store.spaceKey(for: wid) else { return false }
            return activeSpaceKeys.contains(key)
        }
        guard !tiledOnActiveSpaces.isEmpty else { return }

        let onScreen = Dictionary(
            uniqueKeysWithValues: axBridge.onScreenNormalWindows().map { ($0.windowID, $0) }
        )

        var affectedSpaces: Set<SpaceKey> = []
        for wid in tiledOnActiveSpaces {
            guard let snap = onScreen[wid] else {
                // Not on screen while its Space is active -> closed, minimized, hidden, or moved to another Space
                if let space = store.handleWindowUnavailable(wid) {
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

    private func applyFramesIfActive(spaces: Set<SpaceKey>) {
        var frames: [WindowID: CGRect] = [:]
        for space in spaces {
            guard let bounds = displayObserver.usableBounds(for: space) else { continue }
            for (wid, rect) in store.frames(for: space, screenBounds: bounds) {
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

        // Sync AXObserver PIDs to ONLY apps that currently have tiled windows
        var pids: Set<pid_t> = []
        for wid in store.allTiledWindowIDs {
            if let pid = axBridge.pid(for: wid) {
                pids.insert(pid)
            }
        }
        eventMonitor.syncObservedPIDs(pids)

        tiledWindowCount = store.allTiledWindowIDs.count
        if let display = currentMenuDisplay() {
            activeDisplayBounds = display.usableFrameCG
            activeLayoutLeaves = store.tree(for: display.spaceKey).leafPlacements(in: display.usableFrameCG)
        } else {
            activeDisplayBounds = .zero
            activeLayoutLeaves = []
        }
    }

    private func currentMenuDisplay() -> DisplayInfo? {
        let mouseNS = NSEvent.mouseLocation
        let mouseCG = CoordinateSpace.flipY(mouseNS, primaryHeight: displayObserver.primaryScreenHeight)
        return displayObserver.display(containing: mouseCG) ?? displayObserver.displays.first
    }
}
