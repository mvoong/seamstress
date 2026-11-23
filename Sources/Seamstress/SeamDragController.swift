import Cocoa
import CoreGraphics
import Foundation
import SeamstressCore

/// Manages flush seam hover highlights, single-seam and 2-axis `┼` intersection dragging,
/// magnetic detent/alignment feedback, collapse-on-90%, double-click reset, and Escape cancel.
@MainActor
final class SeamDragController {
    private struct Session {
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

    private let store: SpaceLayoutStore
    private let displayObserver: DisplayObserver
    private let axBridge: AXWindowBridge
    private let inputTap: InputEventTap
    private let seamOverlay: SeamHighlightOverlay

    private var session: Session?

    var isActive: Bool { session != nil }

    var onRefreshSeamsAndUI: (() -> Void)?
    var onRecordDeclaredMinSize: ((WindowID) -> Void)?
    var onScheduleMinSizeLearn: ((_ expected: [WindowID: CGRect], _ spaceKey: SpaceKey) -> Void)?

    init(
        store: SpaceLayoutStore,
        displayObserver: DisplayObserver,
        axBridge: AXWindowBridge,
        inputTap: InputEventTap,
        seamOverlay: SeamHighlightOverlay
    ) {
        self.store = store
        self.displayObserver = displayObserver
        self.axBridge = axBridge
        self.inputTap = inputTap
        self.seamOverlay = seamOverlay
    }

    func reset() {
        session = nil
        seamOverlay.hide()
    }

    func reassertCursor() {
        seamOverlay.reassertCursor()
    }

    func handleHoverCandidate(_ hit: SeamHit?, at point: CGPoint, isRunning: Bool, isWindowDragActive: Bool) {
        guard isRunning, session == nil, !isWindowDragActive else {
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
        showOverlay(for: hit, isDragging: false)
    }

    func handleDragBegin(_ hit: SeamHit, at point: CGPoint, isRunning: Bool) {
        guard isRunning, let bounds = displayObserver.usableBounds(for: hit.spaceKey) else { return }

        // Refresh declared minimum sizes once via SkyLight (fast, zero AX IPC) and resolve PIDs.
        var pids: Set<pid_t> = []
        for wid in hit.participatingWindowIDs {
            if let pid = axBridge.pid(for: wid) {
                pids.insert(pid)
            }
            onRecordDeclaredMinSize?(wid)
        }
        axBridge.beginLiveResizeBatch(pids: pids)

        var ratios: [NodeID: CGFloat] = [:]
        var grabOffsets: [NodeID: CGFloat] = [:]
        for seam in hit.allSeams {
            ratios[seam.splitID] = seam.ratio
            grabOffsets[seam.splitID] = point.coordinate(along: seam.axis) - seam.seamPosition
        }

        session = Session(
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

        showOverlay(for: hit, isDragging: true)
    }

    func handleDragMove(to point: CGPoint, shiftDown: Bool) {
        guard var current = session else { return }
        current.lastPoint = point
        current.lastShiftDown = shiftDown

        if !current.hasMoved {
            guard hypot(point.x - current.initialPoint.x, point.y - current.initialPoint.y) >= 1.5 else {
                session = current
                return
            }
            current.hasMoved = true
        }

        let spaceKey = current.hit.spaceKey
        let tree = store.tree(for: spaceKey)
        let allSeams = SeamGeometry.seams(in: tree, spaceKey: spaceKey, bounds: current.screenBounds)

        switch current.hit {
        case .single(let seam):
            let update = SeamGeometry.dragUpdate(
                pointer: point,
                seam: seam,
                tree: tree,
                minSizes: store.learnedMinSizes,
                allSeams: allSeams,
                disableSnapping: shiftDown,
                grabOffset: current.grabOffsets[seam.splitID] ?? 0
            )
            let wasCollapsing = current.lastCollapseTarget != .none
            let isCollapsing = update.collapseTarget != .none
            if !wasCollapsing && isCollapsing {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            current.lastCollapseTarget = update.collapseTarget

            switch update.collapseTarget {
            case .collapseFirst(let expanded), .collapseSecond(let expanded):
                current.lastSnapKey = ""
                current.lastWasClamped = false
                session = current
                seamOverlay.showCollapsePreview(
                    expandedBoundsCG: expanded,
                    axis: seam.axis,
                    primaryScreenHeight: displayObserver.primaryScreenHeight
                )
                return

            case .none:
                let snapKey = Self.snapFeedbackKey(for: update.snapKind)
                emitDragHaptics(snapKey: snapKey, isClamped: update.isClamped, session: &current)

                seamOverlay.showSeam(
                    visualRectCG: update.visualRect,
                    axis: seam.axis,
                    isDragging: true,
                    isClamped: update.isClamped,
                    isSnapped: update.snapKind != .none,
                    primaryScreenHeight: displayObserver.primaryScreenHeight
                )
                let prevRatio = current.lastRatios[seam.splitID] ?? seam.ratio
                if abs(update.ratio - prevRatio) >= 0.001 {
                    current.lastRatios[seam.splitID] = update.ratio
                    session = current
                    let frames = store.updateSeamRatio(
                        spaceKey: seam.spaceKey,
                        splitID: seam.splitID,
                        ratio: update.ratio,
                        screenBounds: current.screenBounds
                    )
                    axBridge.enqueueLiveFrames(frames)
                } else {
                    session = current
                }
            }

        case .intersection(let initialVs, let initialHs):
            let vIDs = Set(initialVs.map(\.splitID))
            let hIDs = Set(initialHs.map(\.splitID))

            var changed = false
            var anyClamped = false
            var snapParts: [String] = []

            // Apply vertical seams first, then re-read the tree so horizontal child splits
            // observe the updated parent bounds rather than stale drag-start bounds.
            applyIntersectionSeams(
                targetIDs: vIDs,
                prefix: "v",
                point: point,
                shiftDown: shiftDown,
                session: &current,
                changed: &changed,
                anyClamped: &anyClamped,
                snapParts: &snapParts
            )
            applyIntersectionSeams(
                targetIDs: hIDs,
                prefix: "h",
                point: point,
                shiftDown: shiftDown,
                session: &current,
                changed: &changed,
                anyClamped: &anyClamped,
                snapParts: &snapParts
            )

            emitDragHaptics(snapKey: snapParts.joined(separator: "|"), isClamped: anyClamped, session: &current)
            session = current

            let updatedTree = store.tree(for: spaceKey)
            let updatedSeams = SeamGeometry.seams(in: updatedTree, spaceKey: spaceKey, bounds: current.screenBounds)
            let updatedVs = updatedSeams.filter { vIDs.contains($0.splitID) }
            let updatedHs = updatedSeams.filter { hIDs.contains($0.splitID) }
            seamOverlay.showIntersection(
                verticalVisualCG: Self.unionVisualRect(of: updatedVs.isEmpty ? initialVs : updatedVs),
                horizontalVisualCG: Self.unionVisualRect(of: updatedHs.isEmpty ? initialHs : updatedHs),
                isDragging: true,
                isClamped: anyClamped,
                isSnapped: !snapParts.isEmpty,
                primaryScreenHeight: displayObserver.primaryScreenHeight
            )
            if changed {
                let frames = store.frames(for: spaceKey, screenBounds: current.screenBounds)
                axBridge.enqueueLiveFrames(frames)
            }
        }
    }

    func handleDragCancel() {
        guard let current = session else { return }
        session = nil
        seamOverlay.hide()

        let finalFrames = store.restoreSeamRatios(
            current.initialRatios,
            in: current.hit.spaceKey,
            screenBounds: current.screenBounds
        )
        axBridge.endLiveResizeBatch(finalFrames: finalFrames, involvedPIDs: current.involvedPIDs)
        onRefreshSeamsAndUI?()
    }

    func handleDragEnd(at point: CGPoint) {
        guard let current = session else { return }
        session = nil
        seamOverlay.hide()

        guard current.hasMoved else {
            axBridge.endLiveResizeBatch(finalFrames: [:], involvedPIDs: current.involvedPIDs)
            return
        }

        let finalFrames: [WindowID: CGRect]
        switch current.hit {
        case .single(let seam):
            switch current.lastCollapseTarget {
            case .collapseFirst, .collapseSecond:
                finalFrames = store.collapseEmptySide(
                    spaceKey: seam.spaceKey,
                    splitID: seam.splitID,
                    screenBounds: current.screenBounds
                ) ?? store.frames(for: seam.spaceKey, screenBounds: current.screenBounds)
            case .none:
                finalFrames = store.frames(for: seam.spaceKey, screenBounds: current.screenBounds)
            }
        case .intersection:
            finalFrames = store.frames(for: current.hit.spaceKey, screenBounds: current.screenBounds)
        }

        axBridge.endLiveResizeBatch(finalFrames: finalFrames, involvedPIDs: current.involvedPIDs)
        onRefreshSeamsAndUI?()
        onScheduleMinSizeLearn?(finalFrames, current.hit.spaceKey)
    }

    func handleDoubleClick(_ hit: SeamHit, isRunning: Bool) {
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
            onRefreshSeamsAndUI?()
        }
    }

    // MARK: - Helpers

    private func applyIntersectionSeams(
        targetIDs: Set<NodeID>,
        prefix: String,
        point: CGPoint,
        shiftDown: Bool,
        session current: inout Session,
        changed: inout Bool,
        anyClamped: inout Bool,
        snapParts: inout [String]
    ) {
        let spaceKey = current.hit.spaceKey
        let tree = store.tree(for: spaceKey)
        let allSeams = SeamGeometry.seams(in: tree, spaceKey: spaceKey, bounds: current.screenBounds)
        let liveTargets = allSeams.filter { targetIDs.contains($0.splitID) }
        let stationarySeams = allSeams.filter { !targetIDs.contains($0.splitID) }

        for seam in liveTargets {
            let update = SeamGeometry.dragUpdate(
                pointer: point,
                seam: seam,
                tree: tree,
                minSizes: store.learnedMinSizes,
                allSeams: stationarySeams,
                disableSnapping: shiftDown,
                grabOffset: current.grabOffsets[seam.splitID] ?? 0
            )
            if update.isClamped { anyClamped = true }
            if update.snapKind != .none {
                snapParts.append("\(prefix):\(seam.splitID):\(Self.snapFeedbackKey(for: update.snapKind))")
            }
            let prev = current.lastRatios[seam.splitID] ?? seam.ratio
            if abs(update.ratio - prev) >= 0.001 {
                current.lastRatios[seam.splitID] = update.ratio
                _ = store.updateSeamRatio(
                    spaceKey: seam.spaceKey,
                    splitID: seam.splitID,
                    ratio: update.ratio,
                    screenBounds: current.screenBounds
                )
                changed = true
            }
        }
    }

    private func emitDragHaptics(snapKey: String, isClamped: Bool, session current: inout Session) {
        if !snapKey.isEmpty && snapKey != current.lastSnapKey {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        current.lastSnapKey = snapKey

        if isClamped && !current.lastWasClamped {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        current.lastWasClamped = isClamped
    }

    private func showOverlay(for hit: SeamHit, isDragging: Bool) {
        switch hit {
        case .single(let seam):
            seamOverlay.showSeam(
                visualRectCG: seam.visualRect,
                axis: seam.axis,
                isDragging: isDragging,
                primaryScreenHeight: displayObserver.primaryScreenHeight
            )
        case .intersection(let vs, let hs):
            seamOverlay.showIntersection(
                verticalVisualCG: Self.unionVisualRect(of: vs),
                horizontalVisualCG: Self.unionVisualRect(of: hs),
                isDragging: isDragging,
                primaryScreenHeight: displayObserver.primaryScreenHeight
            )
        }
    }

    private static func unionVisualRect(of seams: [VisibleSeam]) -> CGRect {
        guard var rect = seams.first?.visualRect else { return .zero }
        for seam in seams.dropFirst() {
            rect = rect.union(seam.visualRect)
        }
        return rect
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
}
