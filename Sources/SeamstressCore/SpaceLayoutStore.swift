import CoreGraphics
import Foundation

/// Outcome of a layout mutation on `SpaceLayoutStore`.
public struct LayoutCommitResult: Equatable, Sendable {
    /// Target frames to apply to tiled windows across affected spaces.
    public let framesToApply: [WindowID: CGRect]
    /// Any displaced window that returned to floating, paired with its restored frame.
    public let detachedWindows: [WindowID: CGRect]
    /// Spaces whose BSP trees changed (callers should refresh visible seams for these).
    public let affectedSpaces: Set<SpaceKey>

    public init(
        framesToApply: [WindowID: CGRect] = [:],
        detachedWindows: [WindowID: CGRect] = [:],
        affectedSpaces: Set<SpaceKey> = []
    ) {
        self.framesToApply = framesToApply
        self.detachedWindows = detachedWindows
        self.affectedSpaces = affectedSpaces
    }
}

/// Snapshot of a space's tree before a drag-detach, allowing a brief grace-window restore
/// if the user presses Option right after starting to drag a tiled window.
public struct DetachUndoSnapshot: Equatable, Sendable {
    public let spaceKey: SpaceKey
    public let previousTree: LayoutTree
    public let windowID: WindowID
    public let savedFloatingFrame: CGRect?
}

/// Pure state store owning all per-(displayUUID, spaceID) BSP trees, saved pre-tiled
/// floating frames, learned per-window minimum sizes, and per-space layout history for
/// restoring quit applications when they relaunch into an unchanged space.
public final class SpaceLayoutStore {
    private struct RecentRemoval {
        let timestamp: TimeInterval
        let appKey: AppKey
        let windowID: WindowID
        let treeBefore: LayoutTree
        let savedFloatingFrame: CGRect?
        let revisionAfter: UInt64
    }

    private static let maxRecentRemovalsPerSpace = 16
    private static let maxPendingQuitSnapshots = 32

    private var trees: [SpaceKey: LayoutTree] = [:]
    private var spaceRevisions: [SpaceKey: UInt64] = [:]
    private var recentRemovals: [SpaceKey: [RecentRemoval]] = [:]
    private var pendingQuitSnapshots: [AppKey: AppQuitSnapshot] = [:]
    private var windowToSpace: [WindowID: SpaceKey] = [:]
    private var savedFloatingFrames: [WindowID: CGRect] = [:]
    private var declaredMinSizes: [WindowID: CGSize] = [:]
    private var settledMinSizes: [WindowID: CGSize] = [:]
    public private(set) var learnedMinSizes: [WindowID: CGSize] = [:]

    public init() {}

    public func tree(for spaceKey: SpaceKey) -> LayoutTree {
        trees[spaceKey] ?? LayoutTree()
    }

    /// Monotonically increasing revision counter bumped whenever `spaceKey`'s layout tree mutates.
    public func revision(for spaceKey: SpaceKey) -> UInt64 {
        spaceRevisions[spaceKey] ?? 0
    }

    /// Adopt a reconstructed layout tree for an empty `spaceKey` (e.g. on relaunch).
    /// Returns the adopted window IDs, or empty if `spaceKey` already has a layout or any
    /// window is already tracked elsewhere.
    @discardableResult
    public func adoptReconstructedTree(_ tree: LayoutTree, for spaceKey: SpaceKey) -> [WindowID] {
        guard trees[spaceKey] == nil, !tree.isEmpty else { return [] }
        let wids = tree.allWindowIDs
        guard wids.allSatisfy({ windowToSpace[$0] == nil }) else { return [] }
        store(tree, for: spaceKey)
        for wid in wids {
            windowToSpace[wid] = spaceKey
        }
        return wids
    }

    public func spaceKey(for windowID: WindowID) -> SpaceKey? {
        windowToSpace[windowID]
    }

    public func isTiled(_ windowID: WindowID) -> Bool {
        windowToSpace[windowID] != nil
    }

    public var allTiledWindowIDs: Set<WindowID> {
        Set(windowToSpace.keys)
    }

    public func savedFloatingFrame(for windowID: WindowID) -> CGRect? {
        savedFloatingFrames[windowID]
    }

    /// Snapshot of all saved pre-tiled floating frames for persistence across relaunches.
    public func savedFloatingFramesSnapshot() -> [WindowID: CGRect] {
        savedFloatingFrames
    }

    /// Restore persisted floating frames, filling only entries not already present.
    public func restoreSavedFloatingFrames(_ frames: [WindowID: CGRect]) {
        for (wid, frame) in frames where savedFloatingFrames[wid] == nil {
            savedFloatingFrames[wid] = frame
        }
    }

    /// Record a WindowServer-declared minimum size floor for `windowID` (replaces any prior
    /// declared value if the app's constraints changed, e.g. after toggling a sidebar).
    public func recordDeclaredMinimumSize(_ size: CGSize, for windowID: WindowID) {
        if size.width > 0 || size.height > 0 {
            declaredMinSizes[windowID] = size
        } else {
            declaredMinSizes.removeValue(forKey: windowID)
        }
        refreshEffectiveMinSize(for: windowID)
    }

    /// Record a settled minimum size observed after a window resisted shrinking past `size`.
    public func recordMinimumSize(_ size: CGSize, for windowID: WindowID) {
        let existing = settledMinSizes[windowID] ?? .zero
        settledMinSizes[windowID] = CGSize(
            width: max(existing.width, size.width),
            height: max(existing.height, size.height)
        )
        refreshEffectiveMinSize(for: windowID)
    }

    /// Lower any previously latched settled minimum that exceeds a live size the window actually
    /// occupies (still bounded below by WindowServer's declared minimum).
    public func reconcileObservedSize(_ observed: CGSize, for windowID: WindowID) {
        guard var settled = settledMinSizes[windowID] else { return }
        var changed = false
        if settled.width > 0 && observed.width > 0 && observed.width < settled.width {
            settled.width = observed.width
            changed = true
        }
        if settled.height > 0 && observed.height > 0 && observed.height < settled.height {
            settled.height = observed.height
            changed = true
        }
        guard changed else { return }
        settledMinSizes[windowID] = settled
        refreshEffectiveMinSize(for: windowID)
    }

    private func refreshEffectiveMinSize(for windowID: WindowID) {
        let declared = declaredMinSizes[windowID] ?? .zero
        let settled = settledMinSizes[windowID] ?? .zero
        let width = max(declared.width, settled.width)
        let height = max(declared.height, settled.height)
        if width > 0 || height > 0 {
            learnedMinSizes[windowID] = CGSize(width: width, height: height)
        } else {
            learnedMinSizes.removeValue(forKey: windowID)
        }
    }

    /// Compute all visible seams across the currently active `(SpaceKey, screenBounds)` pairs.
    public func visibleSeams(for activeSpaces: [(spaceKey: SpaceKey, bounds: CGRect)]) -> [VisibleSeam] {
        var seams: [VisibleSeam] = []
        for entry in activeSpaces {
            guard let tree = trees[entry.spaceKey], !tree.isEmpty else { continue }
            seams.append(contentsOf: SeamGeometry.seams(in: tree, spaceKey: entry.spaceKey, bounds: entry.bounds))
        }
        return seams
    }

    /// Plan an Option-drag drop at `pointer` on `targetSpace`.
    public func planDrop(
        pointer: CGPoint,
        draggedWindowID: WindowID,
        targetSpace: SpaceKey,
        screenBounds: CGRect
    ) -> DropPlan? {
        let targetTree = tree(for: targetSpace)
        return DropPlanner.plan(
            pointer: pointer,
            draggedWindowID: draggedWindowID,
            targetSpace: targetSpace,
            tree: targetTree,
            screenBounds: screenBounds,
            isDraggedWindowTiled: windowToSpace[draggedWindowID] != nil,
            minSizes: learnedMinSizes
        )
    }

    /// Commit a planned Option-drag drop.
    /// - Parameters:
    ///   - plan: The plan produced by `planDrop`.
    ///   - draggedWindowID: The window being dropped.
    ///   - preDragFrame: The dragged window's frame before the drag began (saved as its
    ///     floating restore size if it wasn't already tiled).
    ///   - boundsForSpace: Closure returning usable CG bounds for a given `SpaceKey`.
    public func commitDrop(
        _ plan: DropPlan,
        draggedWindowID: WindowID,
        preDragFrame: CGRect,
        boundsForSpace: (SpaceKey) -> CGRect?
    ) -> LayoutCommitResult {
        let sourceSpace = windowToSpace[draggedWindowID]
        let targetSpace = plan.targetSpace
        var affected: Set<SpaceKey> = [targetSpace]
        if let sourceSpace { affected.insert(sourceSpace) }

        // Remember original floating frame the first time this window becomes tiled.
        if sourceSpace == nil && savedFloatingFrames[draggedWindowID] == nil {
            savedFloatingFrames[draggedWindowID] = preDragFrame
        }

        var detached: [WindowID: CGRect] = [:]

        switch plan.action {
        case .keepInPlace:
            break

        case .shrinkOwnSlot(let leafID, let edge):
            var t = tree(for: targetSpace)
            t.shrinkToEdge(leafID: leafID, edge: edge, ratio: plan.splitRatio)
            store(t, for: targetSpace)

        case .fillEmpty(let leafID):
            let preserveSiblingEmpty: Bool
            if sourceSpace == targetSpace {
                let t = tree(for: targetSpace)
                preserveSiblingEmpty = t.leafID(for: draggedWindowID).map { t.areDirectSiblings($0, leafID) } ?? false
            } else {
                preserveSiblingEmpty = false
            }
            moveWindow(draggedWindowID, from: sourceSpace, to: targetSpace, collapseOld: !preserveSiblingEmpty) { t in
                t.fillEmpty(leafID: leafID, with: draggedWindowID)
            }

        case .splitEmpty(let leafID, let edge):
            moveWindow(draggedWindowID, from: sourceSpace, to: targetSpace, collapseOld: true) { t in
                t.splitEmpty(leafID: leafID, edge: edge, ratio: plan.splitRatio, with: draggedWindowID)
            }

        case .splitOccupied(let leafID, let edge):
            moveWindow(draggedWindowID, from: sourceSpace, to: targetSpace, collapseOld: true) { t in
                t.splitOccupied(leafID: leafID, edge: edge, ratio: plan.splitRatio, with: draggedWindowID)
            }

        case .splitNode(let nodeID, let edge):
            moveWindow(draggedWindowID, from: sourceSpace, to: targetSpace, collapseOld: true) { t in
                t.splitNode(nodeID: nodeID, edge: edge, ratio: plan.splitRatio, with: draggedWindowID)
            }

        case .swapOrReplace(let targetLeafID, let targetWindowID):
            if let sourceSpace {
                if sourceSpace == targetSpace {
                    // Same-space swap of two tiled windows
                    var t = tree(for: targetSpace)
                    t.swapWindows(draggedWindowID, targetWindowID)
                    store(t, for: targetSpace)
                } else {
                    // Cross-monitor swap of two tiled windows
                    var srcTree = tree(for: sourceSpace)
                    var dstTree = tree(for: targetSpace)
                    if let srcLeafID = srcTree.leafID(for: draggedWindowID) {
                        srcTree.replaceWindow(at: srcLeafID, with: targetWindowID)
                        dstTree.replaceWindow(at: targetLeafID, with: draggedWindowID)
                        store(srcTree, for: sourceSpace)
                        store(dstTree, for: targetSpace)
                        windowToSpace[draggedWindowID] = targetSpace
                        windowToSpace[targetWindowID] = sourceSpace
                    }
                }
            } else {
                // Floating window dropped on center of an occupied tiled slot -> replace & float old occupant
                var t = tree(for: targetSpace)
                if let displaced = t.replaceWindow(at: targetLeafID, with: draggedWindowID) {
                    windowToSpace.removeValue(forKey: displaced)
                    if let restored = savedFloatingFrames.removeValue(forKey: displaced) {
                        detached[displaced] = restored
                    } else if let bounds = boundsForSpace(targetSpace) {
                        let fallbackSize = CGSize(width: min(900, bounds.width * 0.6), height: min(650, bounds.height * 0.7))
                        let origin = CGPoint(
                            x: bounds.midX - fallbackSize.width * 0.5,
                            y: bounds.midY - fallbackSize.height * 0.5
                        )
                        detached[displaced] = CGRect(origin: origin, size: fallbackSize)
                    }
                }
                store(t, for: targetSpace)
                windowToSpace[draggedWindowID] = targetSpace
            }
        }

        // Collect all frames to apply across affected spaces
        var framesToApply: [WindowID: CGRect] = [:]
        for space in affected {
            guard let bounds = boundsForSpace(space) else { continue }
            for (wid, rect) in tree(for: space).windowFrames(in: bounds) {
                framesToApply[wid] = rect
            }
        }

        return LayoutCommitResult(
            framesToApply: framesToApply,
            detachedWindows: detached,
            affectedSpaces: affected
        )
    }

    /// Detach a tiled window when dragged normally (without Option).
    /// Collapses its split so neighboring windows expand to fill the vacated space,
    /// and returns the restored floating frame anchored under `cursor` plus an undo snapshot
    /// in case the user presses Option shortly after starting the drag.
    public func detachByUserDrag(
        windowID: WindowID,
        currentFrame: CGRect,
        cursor: CGPoint,
        screenBounds: CGRect? = nil
    ) -> (restoredFrame: CGRect?, spaceKey: SpaceKey, undo: DetachUndoSnapshot)? {
        guard let space = windowToSpace.removeValue(forKey: windowID) else { return nil }
        let previousTree = tree(for: space)
        let savedFrame = savedFloatingFrames.removeValue(forKey: windowID)
        settledMinSizes.removeValue(forKey: windowID)
        refreshEffectiveMinSize(for: windowID)

        var t = previousTree
        t.removeWindowAndCollapse(windowID)
        store(t, for: space)

        let restored: CGRect?
        if let saved = savedFrame {
            restored = CGRect.restoredUnderCursor(
                savedSize: saved.size,
                currentFrame: currentFrame,
                cursor: cursor
            )
        } else if let screenBounds,
                  screenBounds.width > 0,
                  screenBounds.height > 0,
                  (currentFrame.width * currentFrame.height) >= (screenBounds.width * screenBounds.height) * 0.85 {
            let fallbackSize = CGSize(
                width: min(960, screenBounds.width * 0.65),
                height: min(700, screenBounds.height * 0.72)
            )
            restored = CGRect.restoredUnderCursor(
                savedSize: fallbackSize,
                currentFrame: currentFrame,
                cursor: cursor
            )
        } else {
            restored = nil
        }
        let undo = DetachUndoSnapshot(
            spaceKey: space,
            previousTree: previousTree,
            windowID: windowID,
            savedFloatingFrame: savedFrame
        )
        return (restored, space, undo)
    }

    /// Restore a space's tree from a recent `DetachUndoSnapshot` when the user presses Option
    /// right after starting to drag a tiled window.
    @discardableResult
    public func restoreDetachSnapshot(_ snapshot: DetachUndoSnapshot) -> Bool {
        guard windowToSpace[snapshot.windowID] == nil else { return false }
        store(snapshot.previousTree, for: snapshot.spaceKey)
        for wid in snapshot.previousTree.allWindowIDs {
            windowToSpace[wid] = snapshot.spaceKey
        }
        if let saved = snapshot.savedFloatingFrame {
            savedFloatingFrames[snapshot.windowID] = saved
        }
        return true
    }

    /// Detach a tiled window when the user manually resizes it via its own macOS edge/corner.
    /// Expands neighboring tiled windows to fill the vacated slot without touching the resized window's frame.
    @discardableResult
    public func detachByManualResize(windowID: WindowID) -> SpaceKey? {
        guard let space = windowToSpace.removeValue(forKey: windowID) else { return nil }
        savedFloatingFrames.removeValue(forKey: windowID)
        settledMinSizes.removeValue(forKey: windowID)
        refreshEffectiveMinSize(for: windowID)
        var t = tree(for: space)
        t.removeWindowAndCollapse(windowID)
        store(t, for: space)
        return space
    }

    /// Handle a tiled window closing, minimizing, hiding, or entering fullscreen.
    /// Collapses its split so neighboring windows expand to fill the vacated space.
    /// When `appKey` is supplied, records the pre-removal layout in per-space recent history
    /// so an immediately following application quit can coalesce staggered window closures.
    @discardableResult
    public func handleWindowUnavailable(
        _ windowID: WindowID,
        appKey: AppKey? = nil,
        timestamp: TimeInterval = 0
    ) -> SpaceKey? {
        guard let space = windowToSpace.removeValue(forKey: windowID) else { return nil }
        let savedFrame = savedFloatingFrames.removeValue(forKey: windowID)
        declaredMinSizes.removeValue(forKey: windowID)
        settledMinSizes.removeValue(forKey: windowID)
        learnedMinSizes.removeValue(forKey: windowID)
        let treeBefore = tree(for: space)
        var t = treeBefore
        t.removeWindowAndCollapse(windowID)
        store(t, for: space)

        if let appKey {
            var history = recentRemovals[space] ?? []
            history.append(RecentRemoval(
                timestamp: timestamp,
                appKey: appKey,
                windowID: windowID,
                treeBefore: treeBefore,
                savedFloatingFrame: savedFrame,
                revisionAfter: revision(for: space)
            ))
            if history.count > Self.maxRecentRemovalsPerSpace {
                history.removeFirst(history.count - Self.maxRecentRemovalsPerSpace)
            }
            recentRemovals[space] = history
        }
        return space
    }

    /// Handle an application quitting: removes any still-tiled windows in `remainingWindowIDs`,
    /// coalesces them with any unbroken trailing `handleWindowUnavailable` entries for `appKey`
    /// within `coalesceWindow`, and saves a pending restore snapshot per affected Space.
    @discardableResult
    public func recordApplicationQuit(
        appKey: AppKey,
        remainingWindowIDs: [WindowID] = [],
        timestamp: TimeInterval,
        coalesceWindow: TimeInterval = 3.0
    ) -> (affectedSpaces: Set<SpaceKey>, snapshot: AppQuitSnapshot?) {
        var affectedSpaces: Set<SpaceKey> = []
        for wid in remainingWindowIDs {
            if let space = handleWindowUnavailable(wid, appKey: appKey, timestamp: timestamp) {
                affectedSpaces.insert(space)
            }
        }

        var spaceSnapshots: [SpaceQuitSnapshot] = []
        for (spaceKey, removals) in recentRemovals {
            var expectedRev = revision(for: spaceKey)
            guard expectedRev > 0 else { continue }

            var chain: [RecentRemoval] = []
            for entry in removals.reversed() {
                guard entry.revisionAfter == expectedRev,
                      entry.appKey == appKey,
                      timestamp >= entry.timestamp,
                      (timestamp - entry.timestamp) <= coalesceWindow else {
                    break
                }
                chain.append(entry)
                if expectedRev == 0 { break }
                expectedRev &-= 1
            }

            guard !chain.isEmpty else { continue }
            chain.reverse()

            guard let first = chain.first else { continue }
            var seen: Set<WindowID> = []
            var quitWindowIDs: [WindowID] = []
            var savedFrames: [WindowID: CGRect] = [:]
            for entry in chain {
                if seen.insert(entry.windowID).inserted {
                    quitWindowIDs.append(entry.windowID)
                }
                if let frame = entry.savedFloatingFrame, savedFrames[entry.windowID] == nil {
                    savedFrames[entry.windowID] = frame
                }
            }

            spaceSnapshots.append(SpaceQuitSnapshot(
                spaceKey: spaceKey,
                preQuitTree: first.treeBefore,
                quitWindowIDs: quitWindowIDs,
                savedFloatingFrames: savedFrames,
                expectedPostQuitTree: tree(for: spaceKey),
                expectedRevision: revision(for: spaceKey)
            ))
        }

        guard !spaceSnapshots.isEmpty else {
            pendingQuitSnapshots.removeValue(forKey: appKey)
            return (affectedSpaces, nil)
        }

        spaceSnapshots.sort { $0.spaceKey.description < $1.spaceKey.description }
        let snapshot = AppQuitSnapshot(
            appKey: appKey,
            quitTimestamp: timestamp,
            spaces: spaceSnapshots
        )
        pendingQuitSnapshots[appKey] = snapshot
        prunePendingQuitSnapshotsIfNeeded()
        return (affectedSpaces, snapshot)
    }

    /// Returns the subset of `appKey`'s pending quit snapshot whose Spaces are currently active
    /// and have not changed since `appKey` quit, or `nil` if nothing is eligible for restore.
    public func validQuitSnapshot(for appKey: AppKey, activeSpaces: Set<SpaceKey>) -> AppQuitSnapshot? {
        guard let snapshot = pendingQuitSnapshots[appKey] else { return nil }
        let validSpaces = snapshot.spaces.filter { rec in
            activeSpaces.contains(rec.spaceKey)
                && revision(for: rec.spaceKey) == rec.expectedRevision
                && tree(for: rec.spaceKey) == rec.expectedPostQuitTree
        }
        guard !validSpaces.isEmpty else { return nil }
        return AppQuitSnapshot(
            appKey: snapshot.appKey,
            quitTimestamp: snapshot.quitTimestamp,
            spaces: validSpaces
        )
    }

    /// Discard any pending quit restore snapshot for `appKey`.
    public func discardQuitSnapshot(for appKey: AppKey) {
        pendingQuitSnapshots.removeValue(forKey: appKey)
    }

    /// Restore `appKey`'s previous layout(s) using newly launched windows, for every active Space
    /// that has not changed since `appKey` quit. Always consumes the pending snapshot for `appKey`.
    public func restoreQuitApplication(
        appKey: AppKey,
        launchedWindows: [LaunchedWindow],
        activeSpaces: Set<SpaceKey>,
        boundsForSpace: (SpaceKey) -> CGRect?
    ) -> LayoutCommitResult? {
        defer { pendingQuitSnapshots.removeValue(forKey: appKey) }

        guard let validSnapshot = validQuitSnapshot(for: appKey, activeSpaces: activeSpaces) else {
            return nil
        }

        var available = launchedWindows.filter { !isTiled($0.windowID) }
        guard !available.isEmpty else { return nil }

        let eligibleRecords: [(record: SpaceQuitSnapshot, bounds: CGRect)] = validSnapshot.spaces.compactMap { rec in
            guard let bounds = boundsForSpace(rec.spaceKey) else { return nil }
            return (rec, bounds)
        }
        guard !eligibleRecords.isEmpty else { return nil }

        // Pass 1: assign newly launched windows that already opened on the target Space.
        var assignedBySpace: [SpaceKey: [LaunchedWindow]] = [:]
        for entry in eligibleRecords {
            let needed = entry.record.quitWindowIDs.count
            var assigned: [LaunchedWindow] = []
            var remaining: [LaunchedWindow] = []
            for win in available {
                if assigned.count < needed && win.spaceKey == entry.record.spaceKey {
                    assigned.append(win)
                } else {
                    remaining.append(win)
                }
            }
            available = remaining
            assignedBySpace[entry.record.spaceKey] = assigned
        }

        // Pass 2: fill any still-needed slots from remaining unassigned windows (e.g. opened on another active monitor).
        for entry in eligibleRecords {
            var assigned = assignedBySpace[entry.record.spaceKey] ?? []
            let needed = entry.record.quitWindowIDs.count
            if assigned.count < needed && !available.isEmpty {
                let take = min(needed - assigned.count, available.count)
                assigned.append(contentsOf: available.prefix(take))
                available.removeFirst(take)
                assignedBySpace[entry.record.spaceKey] = assigned
            }
        }

        var affectedSpaces: Set<SpaceKey> = []
        var framesToApply: [WindowID: CGRect] = [:]

        for entry in eligibleRecords {
            let rec = entry.record
            let bounds = entry.bounds
            guard let assigned = assignedBySpace[rec.spaceKey], !assigned.isEmpty else {
                continue
            }

            // Pair old slots and new windows deterministically in left-to-right, top-to-bottom order.
            let oldFrames = rec.preQuitTree.windowFrames(in: bounds)
            let sortedOldIDs = rec.quitWindowIDs.sorted { a, b in
                let fa = oldFrames[a] ?? .zero
                let fb = oldFrames[b] ?? .zero
                if abs(fa.minX - fb.minX) > 1 { return fa.minX < fb.minX }
                if abs(fa.minY - fb.minY) > 1 { return fa.minY < fb.minY }
                return a < b
            }
            let sortedNew = assigned.sorted { a, b in
                if abs(a.frame.minX - b.frame.minX) > 1 { return a.frame.minX < b.frame.minX }
                if abs(a.frame.minY - b.frame.minY) > 1 { return a.frame.minY < b.frame.minY }
                return a.windowID < b.windowID
            }

            let pairCount = min(sortedOldIDs.count, sortedNew.count)
            var replacements: [WindowID: WindowID] = [:]
            var unmatched: Set<WindowID> = []
            for idx in 0..<sortedOldIDs.count {
                let oldID = sortedOldIDs[idx]
                if idx < pairCount {
                    let newWin = sortedNew[idx]
                    replacements[oldID] = newWin.windowID
                    if let saved = rec.savedFloatingFrames[oldID] {
                        savedFloatingFrames[newWin.windowID] = saved
                    } else if savedFloatingFrames[newWin.windowID] == nil {
                        savedFloatingFrames[newWin.windowID] = newWin.frame
                    }
                } else {
                    unmatched.insert(oldID)
                }
            }

            var restoredTree = rec.preQuitTree
            restoredTree.remapWindows(replacements: replacements, removing: unmatched)
            guard !restoredTree.isEmpty else { continue }

            store(restoredTree, for: rec.spaceKey)
            for wid in restoredTree.allWindowIDs {
                windowToSpace[wid] = rec.spaceKey
            }
            affectedSpaces.insert(rec.spaceKey)
            for (wid, rect) in restoredTree.windowFrames(in: bounds) {
                framesToApply[wid] = rect
            }
        }

        guard !affectedSpaces.isEmpty else { return nil }
        return LayoutCommitResult(
            framesToApply: framesToApply,
            detachedWindows: [:],
            affectedSpaces: affectedSpaces
        )
    }

    private func prunePendingQuitSnapshotsIfNeeded() {
        while pendingQuitSnapshots.count > Self.maxPendingQuitSnapshots {
            guard let oldestKey = pendingQuitSnapshots.min(by: { $0.value.quitTimestamp < $1.value.quitTimestamp })?.key else {
                break
            }
            pendingQuitSnapshots.removeValue(forKey: oldestKey)
        }
    }

    /// Update a split ratio live during a seam drag and return only the frames inside that space.
    public func updateSeamRatio(
        spaceKey: SpaceKey,
        splitID: NodeID,
        ratio: CGFloat,
        screenBounds: CGRect
    ) -> [WindowID: CGRect] {
        var t = tree(for: spaceKey)
        guard t.setRatio(splitID: splitID, ratio: ratio) else { return [:] }
        store(t, for: spaceKey)
        return t.windowFrames(in: screenBounds)
    }

    /// Collapse an empty child of `splitID` (on drag past 90% or double-click).
    public func collapseEmptySide(
        spaceKey: SpaceKey,
        splitID: NodeID,
        screenBounds: CGRect
    ) -> [WindowID: CGRect]? {
        var t = tree(for: spaceKey)
        guard t.collapseEmptyChild(splitID: splitID) else { return nil }
        store(t, for: spaceKey)
        return t.windowFrames(in: screenBounds)
    }

    /// Double-click on a seam: collapse empty side, or reset ratio to 0.5.
    public func doubleClickSeam(
        spaceKey: SpaceKey,
        splitID: NodeID,
        screenBounds: CGRect
    ) -> [WindowID: CGRect]? {
        var t = tree(for: spaceKey)
        guard t.handleSeamDoubleClick(splitID: splitID) else { return nil }
        store(t, for: spaceKey)
        return t.windowFrames(in: screenBounds)
    }

    /// Equalize all splits in `spaceKey` back to 0.5 and return updated frames, or `nil` if nothing changed.
    public func equalizeSplits(
        in spaceKey: SpaceKey,
        screenBounds: CGRect
    ) -> [WindowID: CGRect]? {
        guard var t = trees[spaceKey], !t.isEmpty else { return nil }
        guard t.equalizeSplits() else { return nil }
        store(t, for: spaceKey)
        return t.windowFrames(in: screenBounds)
    }

    /// Restore a space's split ratios back to pre-drag values (e.g. on Escape cancel)
    /// and return the resulting window frames.
    public func restoreSeamRatios(
        _ ratios: [NodeID: CGFloat],
        in spaceKey: SpaceKey,
        screenBounds: CGRect
    ) -> [WindowID: CGRect] {
        guard var t = trees[spaceKey], !t.isEmpty else { return [:] }
        for (splitID, ratio) in ratios {
            t.setRatio(splitID: splitID, ratio: ratio)
        }
        store(t, for: spaceKey)
        return t.windowFrames(in: screenBounds)
    }

    /// Collapse any split in `spaceKey` where one side is empty and the occupied side's
    /// minimum extent leaves less than 48pt for the empty side (so no dead phantom seam sits
    /// inside an overflowing window). Returns updated frames if any split collapsed.
    public func collapseImpossibleEmptySplits(
        in spaceKey: SpaceKey,
        screenBounds: CGRect
    ) -> [WindowID: CGRect]? {
        guard var t = trees[spaceKey], !t.isEmpty else { return nil }
        var collapsedAny = false

        while let impossibleSplitID = findImpossibleEmptySplit(in: t.root, bounds: screenBounds) {
            guard t.collapseEmptyChild(splitID: impossibleSplitID) else { break }
            collapsedAny = true
        }

        guard collapsedAny else { return nil }
        store(t, for: spaceKey)
        return t.windowFrames(in: screenBounds)
    }

    private func findImpossibleEmptySplit(in node: LayoutTree.Node, bounds: CGRect) -> NodeID? {
        guard case .split(let id, let axis, let ratio, let first, let second) = node else {
            return nil
        }
        let parentLength = bounds.span(along: axis)
        if first.isCompletelyEmpty != second.isCompletelyEmpty {
            let occupied = first.isCompletelyEmpty ? second : first
            let occupiedMin = SeamGeometry.minimumExtent(of: occupied, along: axis, minSizes: learnedMinSizes)
            if occupiedMin + SeamGeometry.minEmptySlotDimension > parentLength {
                return id
            }
        }
        let (firstRect, secondRect, _) = bounds.splitFlush(axis: axis, ratio: ratio)
        return findImpossibleEmptySplit(in: first, bounds: firstRect)
            ?? findImpossibleEmptySplit(in: second, bounds: secondRect)
    }

    /// Recompute frames for a space (e.g. after display resolution or Dock size changes).
    public func frames(for spaceKey: SpaceKey, screenBounds: CGRect) -> [WindowID: CGRect] {
        guard let t = trees[spaceKey], !t.isEmpty else { return [:] }
        return t.windowFrames(in: screenBounds)
    }

    /// Safely move `windowID` into `targetSpace` via `insert`, ensuring same-space moves
    /// mutate the target leaf *before* removing the old leaf (so `leafID` cannot vanish due
    /// to an intermediate double-empty collapse).
    private func moveWindow(
        _ windowID: WindowID,
        from sourceSpace: SpaceKey?,
        to targetSpace: SpaceKey,
        collapseOld: Bool,
        insert: (inout LayoutTree) -> Bool
    ) {
        if sourceSpace == targetSpace {
            var t = tree(for: targetSpace)
            let oldLeafID = t.leafID(for: windowID)
            guard insert(&t) else { return }
            if let oldLeafID {
                if collapseOld {
                    t.removeLeafAndCollapse(leafID: oldLeafID)
                } else {
                    t.removeLeaf(leafID: oldLeafID)
                }
            }
            store(t, for: targetSpace)
            windowToSpace[windowID] = targetSpace
        } else {
            if let sourceSpace {
                var src = tree(for: sourceSpace)
                if collapseOld {
                    src.removeWindowAndCollapse(windowID)
                } else {
                    src.removeWindow(windowID)
                }
                store(src, for: sourceSpace)
            }
            var dst = tree(for: targetSpace)
            guard insert(&dst) else { return }
            store(dst, for: targetSpace)
            windowToSpace[windowID] = targetSpace
        }
    }

    private func store(_ tree: LayoutTree, for spaceKey: SpaceKey) {
        let previous = trees[spaceKey]
        if tree.isEmpty {
            if previous != nil {
                trees.removeValue(forKey: spaceKey)
                spaceRevisions[spaceKey, default: 0] &+= 1
            }
        } else {
            if previous != tree {
                trees[spaceKey] = tree
                spaceRevisions[spaceKey, default: 0] &+= 1
            }
        }
    }
}
