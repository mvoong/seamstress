import Cocoa
import CoreGraphics
import Foundation
import SeamstressCore

/// Manages window dragging: normal detach with pre-tiled size restore, manual edge-resize detach,
/// `⌥` / `⌃⌘` snap-drop preview & commit, late-modifier grace undo, Escape drag cancel, and
/// post-commit frame drift verification.
@MainActor
final class WindowDragController {
    private struct Session {
        enum Phase {
            case pending
            case checkingTileability
            case moving
            case ignored
        }

        let id: UInt64
        let window: CGWindowSnapshot
        let pressPoint: CGPoint
        let preDragFrame: CGRect
        let startedWithGestureDragModifier: Bool
        var phase: Phase = .pending
        var latestPoint: CGPoint
        var latestSnapModifierDown: Bool
        var currentPlan: DropPlan?
        var detachUndo: DetachUndoSnapshot?
        var detachedAt: TimeInterval?
        var pendingMouseUp: (point: CGPoint, snapModifierDown: Bool)?
    }

    /// Grace window (seconds) during which pressing Option right after starting a normal drag
    /// of a tiled window restores the pre-detach layout so swapping/re-splitting still works.
    private static let lateOptionGraceWindow: TimeInterval = 0.45

    private let store: SpaceLayoutStore
    private let displayObserver: DisplayObserver
    private let axBridge: AXWindowBridge
    private let inputTap: InputEventTap
    private let dropOverlay: DropPreviewOverlay
    private let seamOverlay: SeamHighlightOverlay

    private var session: Session?
    private var nextSessionID: UInt64 = 1

    var isActive: Bool { session != nil }

    var onRefreshSeamsAndUI: (() -> Void)?
    var onPersistFloatingFrames: (() -> Void)?
    var onRecordDeclaredMinSize: ((WindowID) -> Void)?
    var onScheduleMinSizeLearn: ((_ expected: [WindowID: CGRect], _ spaceKey: SpaceKey) -> Void)?
    var onApplyFramesIfActive: ((_ spaces: Set<SpaceKey>, _ excluding: WindowID?) -> Void)?
    var isIdleForVerification: (() -> Bool)?

    init(
        store: SpaceLayoutStore,
        displayObserver: DisplayObserver,
        axBridge: AXWindowBridge,
        inputTap: InputEventTap,
        dropOverlay: DropPreviewOverlay,
        seamOverlay: SeamHighlightOverlay
    ) {
        self.store = store
        self.displayObserver = displayObserver
        self.axBridge = axBridge
        self.inputTap = inputTap
        self.dropOverlay = dropOverlay
        self.seamOverlay = seamOverlay
    }

    func reset() {
        session = nil
        dropOverlay.hide()
        inputTap.setHasActiveWindowMove(false)
    }

    func handleMouseDown(at point: CGPoint, snapModifierDown: Bool, isGestureDrag: Bool, isRunning: Bool) {
        guard isRunning else { return }
        seamOverlay.hide()
        dropOverlay.hide()
        inputTap.setHasActiveWindowMove(false)

        guard let top = axBridge.topWindow(at: point) else {
            session = nil
            return
        }

        let sid = nextSessionID
        nextSessionID &+= 1
        session = Session(
            id: sid,
            window: top,
            pressPoint: point,
            preDragFrame: top.bounds,
            startedWithGestureDragModifier: isGestureDrag,
            phase: .pending,
            latestPoint: point,
            latestSnapModifierDown: snapModifierDown
        )
    }

    func handleMouseDragged(to point: CGPoint, snapModifierDown: Bool) {
        guard var current = session else { return }
        current.latestPoint = point
        current.latestSnapModifierDown = snapModifierDown

        switch current.phase {
        case .ignored:
            return

        case .checkingTileability:
            session = current
            return

        case .pending:
            let moved = hypot(point.x - current.pressPoint.x, point.y - current.pressPoint.y)
            guard moved >= 4 else {
                session = current
                return
            }

            guard let liveBounds = axBridge.windowBounds(windowID: current.window.windowID) else {
                current.phase = .ignored
                session = current
                return
            }

            let dw = abs(liveBounds.width - current.window.bounds.width)
            let dh = abs(liveBounds.height - current.window.bounds.height)
            let isPotentialManualResize = !current.startedWithGestureDragModifier
                && current.window.bounds.isPointNearEdge(current.pressPoint)
            if isPotentialManualResize && (dw > 1.5 || dh > 1.5) {
                // Native window edge/corner resize: if the window was tiled, detach it cleanly
                // and expand neighbors so no stale phantom seam remains behind.
                if store.isTiled(current.window.windowID),
                   let space = store.detachByManualResize(windowID: current.window.windowID) {
                    SeamstressLog.layout.info("Detached window \(current.window.windowID) on manual edge resize")
                    onApplyFramesIfActive?([space], nil)
                    onRefreshSeamsAndUI?()
                }
                current.phase = .ignored
                session = current
                return
            }

            let dx = abs(liveBounds.origin.x - current.window.bounds.origin.x)
            let dy = abs(liveBounds.origin.y - current.window.bounds.origin.y)
            guard dx >= 2 || dy >= 2 else {
                // Likely text selection or dragging content inside the window.
                session = current
                return
            }

            // Confirmed window move: check cached tileability synchronously (0ms, zero IPC),
            // or verify off-main on the target PID's queue so a hung app never stalls the main thread.
            if axBridge.isKnownTileable(windowID: current.window.windowID, pid: current.window.ownerPID) {
                activateMove(session: &current, liveBounds: liveBounds, point: point, snapModifierDown: snapModifierDown)
            } else {
                current.phase = .checkingTileability
                session = current
                let sessionID = current.id
                let wid = current.window.windowID
                let pid = current.window.ownerPID
                axBridge.checkTileabilityAsync(windowID: wid, pid: pid) { [weak self] result in
                    guard let self, var pending = self.session,
                          pending.id == sessionID,
                          pending.phase == .checkingTileability else {
                        return
                    }
                    guard result == .tileable else {
                        if pending.pendingMouseUp != nil {
                            self.session = nil
                        } else {
                            pending.phase = .ignored
                            self.session = pending
                        }
                        return
                    }
                    let bounds = self.axBridge.windowBounds(windowID: wid) ?? pending.preDragFrame
                    self.activateMove(
                        session: &pending,
                        liveBounds: bounds,
                        point: pending.latestPoint,
                        snapModifierDown: pending.latestSnapModifierDown
                    )
                    if let deferredUp = pending.pendingMouseUp {
                        self.finishMouseUp(session: pending, at: deferredUp.point, snapModifierDown: deferredUp.snapModifierDown)
                    } else {
                        self.updateDropPreview(
                            session: &pending,
                            at: pending.latestPoint,
                            snapModifierDown: pending.latestSnapModifierDown
                        )
                        self.session = pending
                    }
                }
                return
            }

        case .moving:
            break
        }

        updateDropPreview(session: &current, at: point, snapModifierDown: snapModifierDown)
        session = current
    }

    func handleSnapModifierChanged(snapModifierDown: Bool, point: CGPoint) {
        guard var current = session else { return }
        current.latestPoint = point
        current.latestSnapModifierDown = snapModifierDown

        if current.phase == .checkingTileability {
            session = current
            return
        }
        guard current.phase == .moving else { return }

        if snapModifierDown {
            // Late-modifier grace window: if the user started dragging a tiled window and pressed
            // Option (or Ctrl+Cmd) within 0.45s, restore its pre-detach layout so center-swap & T-splits work seamlessly.
            if let undo = current.detachUndo,
               let detachedAt = current.detachedAt,
               ProcessInfo.processInfo.systemUptime - detachedAt <= Self.lateOptionGraceWindow {
                if store.restoreDetachSnapshot(undo) {
                    current.detachUndo = nil
                    current.detachedAt = nil
                    onApplyFramesIfActive?([undo.spaceKey], current.window.windowID)
                    onRefreshSeamsAndUI?()
                }
            }
            updateDropPreview(session: &current, at: point, snapModifierDown: true)
            session = current
        } else {
            updateDropPreview(session: &current, at: point, snapModifierDown: false)

            // If user started dragging a tiled window with a snap modifier held and then released it
            // mid-drag, detach it to floating right away.
            if store.isTiled(current.window.windowID) {
                let bounds = axBridge.windowBounds(windowID: current.window.windowID) ?? current.preDragFrame
                current.detachUndo = detachTiledWindowDuringDrag(
                    windowID: current.window.windowID,
                    currentFrame: bounds,
                    cursor: point
                )
                current.detachedAt = ProcessInfo.processInfo.systemUptime
            }
            session = current
        }
    }

    func handleDragCancel() {
        guard let current = session else { return }
        session = nil
        dropOverlay.hide()
        inputTap.setHasActiveWindowMove(false)

        var framesToRestore: [WindowID: CGRect] = [:]
        if let undo = current.detachUndo {
            if store.restoreDetachSnapshot(undo) {
                onPersistFloatingFrames?()
                if let bounds = displayObserver.usableBounds(for: undo.spaceKey) {
                    framesToRestore = store.frames(for: undo.spaceKey, screenBounds: bounds)
                }
            }
        } else if let space = store.spaceKey(for: current.window.windowID),
                  let bounds = displayObserver.usableBounds(for: space),
                  let rect = store.frames(for: space, screenBounds: bounds)[current.window.windowID] {
            framesToRestore = [current.window.windowID: rect]
        } else {
            framesToRestore = [current.window.windowID: current.preDragFrame]
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        if !framesToRestore.isEmpty {
            let expected = framesToRestore
            axBridge.applyFrames(expected, crossMonitorSafe: true) { [weak self] in
                self?.scheduleDriftCorrection(expected: expected, after: 0.04)
            }
        }

        onRefreshSeamsAndUI?()
    }

    func handleMouseUp(at point: CGPoint, snapModifierDown: Bool) {
        dropOverlay.hide(animated: true)
        inputTap.setHasActiveWindowMove(false)
        guard var current = session else { return }

        if current.phase == .checkingTileability {
            // Defer drop resolution briefly until the off-main tileability check returns.
            current.pendingMouseUp = (point, snapModifierDown)
            session = current
            return
        }

        finishMouseUp(session: current, at: point, snapModifierDown: snapModifierDown)
    }

    // MARK: - Internal helpers

    private func activateMove(
        session current: inout Session,
        liveBounds: CGRect,
        point: CGPoint,
        snapModifierDown: Bool
    ) {
        onRecordDeclaredMinSize?(current.window.windowID)
        current.phase = .moving
        inputTap.setHasActiveWindowMove(true)

        // Dragging a tiled window WITHOUT a snap modifier detaches it immediately and expands neighbors,
        // while keeping a short undo snapshot in case Option or Ctrl+Cmd is pressed right after starting.
        if !snapModifierDown && store.isTiled(current.window.windowID) {
            current.detachUndo = detachTiledWindowDuringDrag(
                windowID: current.window.windowID,
                currentFrame: liveBounds,
                cursor: point
            )
            current.detachedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    private func updateDropPreview(
        session current: inout Session,
        at point: CGPoint,
        snapModifierDown: Bool
    ) {
        if snapModifierDown {
            let previousAction = current.currentPlan?.action
            let plan = computeDropPlan(at: point, draggedWindowID: current.window.windowID)
            current.currentPlan = plan
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
            current.currentPlan = nil
            dropOverlay.hide(animated: true)
        }
    }

    private func finishMouseUp(session current: Session, at point: CGPoint, snapModifierDown: Bool) {
        session = nil
        dropOverlay.hide(animated: true)
        inputTap.setHasActiveWindowMove(false)

        guard current.phase == .moving, snapModifierDown else { return }

        let plan = computeDropPlan(at: point, draggedWindowID: current.window.windowID) ?? current.currentPlan
        guard let plan else { return }

        let commit = store.commitDrop(
            plan,
            draggedWindowID: current.window.windowID,
            preDragFrame: current.preDragFrame,
            boundsForSpace: { [weak self] spaceKey in
                self?.displayObserver.usableBounds(for: spaceKey)
            }
        )
        onPersistFloatingFrames?()

        onRecordDeclaredMinSize?(current.window.windowID)
        SeamstressLog.layout.info("Committed drop for window \(current.window.windowID) into \(plan.targetSpace.description, privacy: .public)")

        var allFrames = commit.framesToApply
        for (wid, restored) in commit.detachedWindows {
            allFrames[wid] = restored
        }

        let draggedID = current.window.windowID
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
                self.scheduleDriftCorrection(
                    expected: [draggedID: expected],
                    after: 0.04,
                    requireIdle: false
                ) { [weak self] wid in
                    self?.store.isTiled(wid) == true
                }
            }
            if needsMultiWindowVerify {
                self.scheduleDriftCorrection(expected: expectedAll, after: 0.11) { [weak self] wid in
                    guard let self else { return false }
                    return self.store.isTiled(wid) || detachedIDs.contains(wid)
                }
            }
            self.onScheduleMinSizeLearn?(expectedTargetFrames, targetSpace)
        }

        onRefreshSeamsAndUI?()
    }

    private func scheduleDriftCorrection(
        expected: [WindowID: CGRect],
        after delay: TimeInterval,
        requireIdle: Bool = true,
        filter: (@MainActor (WindowID) -> Bool)? = nil
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if requireIdle, self.isIdleForVerification?() != true { return }

            var drifted: [WindowID: CGRect] = [:]
            for (wid, target) in expected {
                if let filter, !filter(wid) { continue }
                if let actual = self.axBridge.windowBounds(windowID: wid),
                   actual.manhattanDistance(to: target) > 3 {
                    drifted[wid] = target
                }
            }
            if !drifted.isEmpty {
                self.axBridge.applyFrames(drifted, crossMonitorSafe: true)
            }
        }
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
        onPersistFloatingFrames?()
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
        onRefreshSeamsAndUI?()
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
}
