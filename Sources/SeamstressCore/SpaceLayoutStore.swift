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

/// Pure state store owning all per-(displayUUID, spaceID) BSP trees, saved pre-tiled
/// floating frames, and learned per-window minimum sizes.
public final class SpaceLayoutStore {
    private var trees: [SpaceKey: LayoutTree] = [:]
    private var windowToSpace: [WindowID: SpaceKey] = [:]
    private var savedFloatingFrames: [WindowID: CGRect] = [:]
    public private(set) var learnedMinSizes: [WindowID: CGSize] = [:]

    public init() {}

    public func tree(for spaceKey: SpaceKey) -> LayoutTree {
        trees[spaceKey] ?? LayoutTree()
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

    public func recordMinimumSize(_ size: CGSize, for windowID: WindowID) {
        let existing = learnedMinSizes[windowID] ?? .zero
        learnedMinSizes[windowID] = CGSize(
            width: max(existing.width, size.width),
            height: max(existing.height, size.height)
        )
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
            screenBounds: screenBounds
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
            t.shrinkToEdge(leafID: leafID, edge: edge)
            store(t, for: targetSpace)

        case .fillEmpty(let leafID):
            moveWindow(draggedWindowID, from: sourceSpace, to: targetSpace) { t in
                t.fillEmpty(leafID: leafID, with: draggedWindowID)
            }

        case .splitEmpty(let leafID, let edge):
            moveWindow(draggedWindowID, from: sourceSpace, to: targetSpace) { t in
                t.splitEmpty(leafID: leafID, edge: edge, with: draggedWindowID)
            }

        case .splitOccupied(let leafID, let edge):
            moveWindow(draggedWindowID, from: sourceSpace, to: targetSpace) { t in
                t.splitOccupied(leafID: leafID, edge: edge, with: draggedWindowID)
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
    /// Leaves its BSP slot `.empty` and returns the restored floating frame anchored under `cursor`.
    public func detachByUserDrag(
        windowID: WindowID,
        currentFrame: CGRect,
        cursor: CGPoint
    ) -> (restoredFrame: CGRect?, spaceKey: SpaceKey)? {
        guard let space = windowToSpace.removeValue(forKey: windowID) else { return nil }
        var t = tree(for: space)
        t.removeWindow(windowID)
        store(t, for: space)

        let restored: CGRect?
        if let saved = savedFloatingFrames.removeValue(forKey: windowID) {
            restored = CGRect.restoredUnderCursor(
                savedSize: saved.size,
                currentFrame: currentFrame,
                cursor: cursor
            )
        } else {
            restored = nil
        }
        return (restored, space)
    }

    /// Handle a tiled window closing, minimizing, hiding, or entering fullscreen.
    /// Collapses its split so neighboring windows expand to fill the vacated space.
    @discardableResult
    public func handleWindowUnavailable(_ windowID: WindowID) -> SpaceKey? {
        guard let space = windowToSpace.removeValue(forKey: windowID) else { return nil }
        savedFloatingFrames.removeValue(forKey: windowID)
        learnedMinSizes.removeValue(forKey: windowID)
        var t = tree(for: space)
        t.removeWindowAndCollapse(windowID)
        store(t, for: space)
        return space
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
        insert: (inout LayoutTree) -> Bool
    ) {
        if sourceSpace == targetSpace {
            var t = tree(for: targetSpace)
            let oldLeafID = t.leafID(for: windowID)
            guard insert(&t) else { return }
            if let oldLeafID {
                t.removeLeaf(leafID: oldLeafID)
            }
            store(t, for: targetSpace)
            windowToSpace[windowID] = targetSpace
        } else {
            if let sourceSpace {
                var src = tree(for: sourceSpace)
                src.removeWindow(windowID)
                store(src, for: sourceSpace)
            }
            var dst = tree(for: targetSpace)
            guard insert(&dst) else { return }
            store(dst, for: targetSpace)
            windowToSpace[windowID] = targetSpace
        }
    }

    private func store(_ tree: LayoutTree, for spaceKey: SpaceKey) {
        if tree.isEmpty {
            trees.removeValue(forKey: spaceKey)
        } else {
            trees[spaceKey] = tree
        }
    }
}
