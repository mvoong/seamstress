import CoreGraphics
import Foundation

/// Visual style hint for the drop preview overlay.
public enum DropPreviewKind: Equatable, Sendable {
    case fill
    case split
    case splitContainer
    case swap
    case replace
}

/// Pure, resolved drop action for an Option-drag release at a cursor point.
public struct DropPlan: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Fill an existing empty slot 100%.
        case fillEmpty(leafID: NodeID)
        /// Take half of an empty slot along `edge`, leaving the other half empty.
        case splitEmpty(leafID: NodeID, edge: SplitEdge)
        /// Split an occupied slot 50/50 along `edge`.
        case splitOccupied(leafID: NodeID, edge: SplitEdge)
        /// Split an entire `.split` container 50/50 along `edge` (triggered near its T-junction).
        case splitNode(nodeID: NodeID, edge: SplitEdge)
        /// Swap with an occupied slot (or replace if dragged window is floating).
        case swapOrReplace(leafID: NodeID, targetWindowID: WindowID)
        /// Dragged tiled window dropped back onto the center of its own slot.
        case keepInPlace(leafID: NodeID)
        /// Dragged tiled window dropped onto an edge of its own slot -> shrink to that half.
        case shrinkOwnSlot(leafID: NodeID, edge: SplitEdge)
    }

    public let targetSpace: SpaceKey
    public let action: Action
    public let previewRect: CGRect
    public let previewKind: DropPreviewKind
    public let splitRatio: CGFloat

    public init(
        targetSpace: SpaceKey,
        action: Action,
        previewRect: CGRect,
        previewKind: DropPreviewKind,
        splitRatio: CGFloat = 0.5
    ) {
        self.targetSpace = targetSpace
        self.action = action
        self.previewRect = previewRect
        self.previewKind = previewKind
        self.splitRatio = splitRatio
    }
}

/// Pure hit-testing planner for Option-drag drops.
public enum DropPlanner {
    /// Edge band fraction for empty slots (18% from each edge snaps to a half; center 64% fills 100%).
    public static let emptyEdgeFraction: CGFloat = 0.18
    /// Maximum pixel width/height for empty-slot edge bands on ultrawide displays so edge targeting feels natural.
    public static let maxEmptyEdgePixels: CGFloat = 220

    /// Center box fraction for occupied slots (inner 36% swaps; outer bands split 50/50).
    public static let occupiedCenterFraction: CGFloat = 0.36

    /// Half-width along the seam perpendicular to the T edge (±52pt around the seam line).
    public static let tJunctionHalfSpan: CGFloat = 52
    /// Depth inward from the split container's outer edge for T-junction targeting.
    public static let tJunctionMaxDepth: CGFloat = 68

    public static func plan(
        pointer: CGPoint,
        draggedWindowID: WindowID,
        targetSpace: SpaceKey,
        tree: LayoutTree,
        screenBounds: CGRect,
        isDraggedWindowTiled: Bool? = nil,
        minSizes: [WindowID: CGSize] = [:]
    ) -> DropPlan? {
        guard screenBounds.contains(pointer) else { return nil }

        let draggedMinForAxis: (SplitAxis) -> CGFloat = { axis in
            SeamGeometry.minimumExtent(
                of: .window(id: 0, windowID: draggedWindowID),
                along: axis,
                minSizes: minSizes
            )
        }

        // Check T-junctions of existing `.split` containers first: dragging near the top/bottom
        // of a vertical seam (┬ / ┴) or left/right of a horizontal seam (├ / ┤) splits that
        // entire split container along the perpendicular axis.
        if let tHit = tJunctionHit(pointer: pointer, in: tree.root, bounds: screenBounds),
           let ratio = tJunctionSplitRatio(
               tHit: tHit,
               draggedWindowID: draggedWindowID,
               tree: tree,
               screenBounds: screenBounds,
               minSizes: minSizes
           ) {
            let fallbackPreview = splitRect(of: tHit.containerBounds, edge: tHit.edge, ratio: ratio)
            let preview = simulatedPreviewRect(
                tree: tree,
                draggedWindowID: draggedWindowID,
                screenBounds: screenBounds,
                fallback: fallbackPreview
            ) { simulated in
                simulated.splitNode(nodeID: tHit.nodeID, edge: tHit.edge, ratio: ratio, with: draggedWindowID)
            }
            return DropPlan(
                targetSpace: targetSpace,
                action: .splitNode(nodeID: tHit.nodeID, edge: tHit.edge),
                previewRect: preview,
                previewKind: .splitContainer,
                splitRatio: ratio
            )
        }

        guard let leaf = tree.leaf(at: pointer, in: screenBounds) else {
            return nil
        }

        let cell = leaf.frame
        guard cell.width > 1, cell.height > 1 else { return nil }

        // Case 1: Empty space (either empty screen or empty BSP slot)
        if leaf.isEmpty {
            for edge in edgeBandCandidates(point: pointer, in: cell, fraction: emptyEdgeFraction, maxPixels: maxEmptyEdgePixels) {
                let winMin = draggedMinForAxis(edge.axis)
                let emptyMin = SeamGeometry.defaultMinLeafDimension
                let parentLength = cell.span(along: edge.axis)
                let firstMin = edge.isFirstChild ? winMin : emptyMin
                let secondMin = edge.isFirstChild ? emptyMin : winMin
                if let ratio = feasibleSplitRatio(
                    parentLength: parentLength,
                    firstMinPx: firstMin,
                    secondMinPx: secondMin
                ) {
                    let preview = splitRect(of: cell, edge: edge, ratio: ratio)
                    return DropPlan(
                        targetSpace: targetSpace,
                        action: .splitEmpty(leafID: leaf.leafID, edge: edge),
                        previewRect: preview,
                        previewKind: .split,
                        splitRatio: ratio
                    )
                }
            }
            return DropPlan(
                targetSpace: targetSpace,
                action: .fillEmpty(leafID: leaf.leafID),
                previewRect: cell,
                previewKind: .fill
            )
        }

        guard let occupant = leaf.windowID else { return nil }

        // Case 2: Dragging a tiled window over its own slot
        if occupant == draggedWindowID {
            for edge in edgeBandCandidates(point: pointer, in: cell, fraction: emptyEdgeFraction, maxPixels: maxEmptyEdgePixels) {
                let winMin = draggedMinForAxis(edge.axis)
                let emptyMin = SeamGeometry.defaultMinLeafDimension
                let parentLength = cell.span(along: edge.axis)
                let firstMin = edge.isFirstChild ? winMin : emptyMin
                let secondMin = edge.isFirstChild ? emptyMin : winMin
                if let ratio = feasibleSplitRatio(
                    parentLength: parentLength,
                    firstMinPx: firstMin,
                    secondMinPx: secondMin
                ) {
                    let preview = splitRect(of: cell, edge: edge, ratio: ratio)
                    return DropPlan(
                        targetSpace: targetSpace,
                        action: .shrinkOwnSlot(leafID: leaf.leafID, edge: edge),
                        previewRect: preview,
                        previewKind: .split,
                        splitRatio: ratio
                    )
                }
            }
            return DropPlan(
                targetSpace: targetSpace,
                action: .keepInPlace(leafID: leaf.leafID),
                previewRect: cell,
                previewKind: .fill
            )
        }

        // Case 3: Occupied slot belonging to another window
        let centerInsetX = cell.width * (1 - occupiedCenterFraction) * 0.5
        let centerInsetY = cell.height * (1 - occupiedCenterFraction) * 0.5
        let centerRect = cell.insetBy(dx: centerInsetX, dy: centerInsetY)
        let isTiled = isDraggedWindowTiled ?? tree.contains(windowID: draggedWindowID)

        if centerRect.contains(pointer) {
            return DropPlan(
                targetSpace: targetSpace,
                action: .swapOrReplace(leafID: leaf.leafID, targetWindowID: occupant),
                previewRect: cell,
                previewKind: isTiled ? .swap : .replace
            )
        }

        let effectiveCell: CGRect
        if let oldLeafID = tree.leafID(for: draggedWindowID) {
            var collapsed = tree
            collapsed.removeLeafAndCollapse(leafID: oldLeafID)
            effectiveCell = collapsed.windowFrames(in: screenBounds)[occupant] ?? cell
        } else {
            effectiveCell = cell
        }

        func ratioForOccupiedEdge(_ edge: SplitEdge) -> CGFloat? {
            let draggedMin = draggedMinForAxis(edge.axis)
            let occupantMin = SeamGeometry.minimumExtent(
                of: .window(id: 0, windowID: occupant),
                along: edge.axis,
                minSizes: minSizes
            )
            let effectiveLength = effectiveCell.span(along: edge.axis)
            let firstMin = edge.isFirstChild ? draggedMin : occupantMin
            let secondMin = edge.isFirstChild ? occupantMin : draggedMin
            return feasibleSplitRatio(
                parentLength: effectiveLength,
                firstMinPx: firstMin,
                secondMinPx: secondMin
            )
        }

        let canSplitVertical = ratioForOccupiedEdge(.left) != nil
        let canSplitHorizontal = ratioForOccupiedEdge(.top) != nil

        // When one split axis is impossible due to minimum window sizes (e.g. a narrow column
        // that can't split left/right), allocate the full outer bands of the feasible axis
        // instead of letting infeasible edge triangles swallow them into swap/replace.
        let chosenEdge: SplitEdge?
        if canSplitVertical && canSplitHorizontal {
            chosenEdge = nearestEdge(point: pointer, in: cell)
        } else if canSplitHorizontal {
            if pointer.y < centerRect.minY {
                chosenEdge = .top
            } else if pointer.y > centerRect.maxY {
                chosenEdge = .bottom
            } else {
                chosenEdge = nil
            }
        } else if canSplitVertical {
            if pointer.x < centerRect.minX {
                chosenEdge = .left
            } else if pointer.x > centerRect.maxX {
                chosenEdge = .right
            } else {
                chosenEdge = nil
            }
        } else {
            chosenEdge = nil
        }

        guard let edge = chosenEdge, let ratio = ratioForOccupiedEdge(edge) else {
            // Cannot fit both windows along the targeted axis; fall back to swap/replace.
            return DropPlan(
                targetSpace: targetSpace,
                action: .swapOrReplace(leafID: leaf.leafID, targetWindowID: occupant),
                previewRect: cell,
                previewKind: isTiled ? .swap : .replace
            )
        }

        let fallbackPreview = splitRect(of: effectiveCell, edge: edge, ratio: ratio)
        let preview = simulatedPreviewRect(
            tree: tree,
            draggedWindowID: draggedWindowID,
            screenBounds: screenBounds,
            fallback: fallbackPreview
        ) { simulated in
            simulated.splitOccupied(leafID: leaf.leafID, edge: edge, ratio: ratio, with: draggedWindowID)
        }
        return DropPlan(
            targetSpace: targetSpace,
            action: .splitOccupied(leafID: leaf.leafID, edge: edge),
            previewRect: preview,
            previewKind: .split,
            splitRatio: ratio
        )
    }

    /// Computes a clamped initial split ratio (preferring 0.5) when both sides' minimum extents
    /// can fit inside `parentLength`, or returns `nil` when the split is geometrically impossible.
    private static func feasibleSplitRatio(
        parentLength: CGFloat,
        firstMinPx: CGFloat,
        secondMinPx: CGFloat
    ) -> CGFloat? {
        guard parentLength > 1 else { return nil }
        guard firstMinPx + secondMinPx <= parentLength + 0.5 else { return nil }
        let minRatio = max(0.05, firstMinPx / parentLength)
        let maxRatio = min(0.95, 1.0 - (secondMinPx / parentLength))
        guard minRatio <= maxRatio else { return nil }
        return min(max(0.5, minRatio), maxRatio)
    }

    private static func tJunctionSplitRatio(
        tHit: TJunctionCandidate,
        draggedWindowID: WindowID,
        tree: LayoutTree,
        screenBounds: CGRect,
        minSizes: [WindowID: CGSize]
    ) -> CGFloat? {
        let effectiveBounds: CGRect
        let existingNode: LayoutTree.Node?
        if let oldLeafID = tree.leafID(for: draggedWindowID) {
            // If `oldLeafID` is a direct child of `tHit.nodeID`, collapsing it promotes its sibling
            // into `tHit.nodeID`'s slot; capture that sibling's ID before collapsing so nested
            // T-junctions evaluate the promoted sibling rather than the whole root tree.
            let promotedSiblingID: NodeID?
            if case .split(_, _, _, let first, let second) = tree.node(withID: tHit.nodeID) {
                if first.id == oldLeafID {
                    promotedSiblingID = second.id
                } else if second.id == oldLeafID {
                    promotedSiblingID = first.id
                } else {
                    promotedSiblingID = nil
                }
            } else {
                promotedSiblingID = nil
            }

            var collapsed = tree
            collapsed.removeLeafAndCollapse(leafID: oldLeafID)
            if let survivingNode = collapsed.node(withID: tHit.nodeID) {
                existingNode = survivingNode
                effectiveBounds = nodeBounds(of: tHit.nodeID, in: collapsed.root, bounds: screenBounds) ?? tHit.containerBounds
            } else if let siblingID = promotedSiblingID, let siblingNode = collapsed.node(withID: siblingID) {
                existingNode = siblingNode
                effectiveBounds = nodeBounds(of: siblingID, in: collapsed.root, bounds: screenBounds) ?? tHit.containerBounds
            } else {
                existingNode = nil
                effectiveBounds = tHit.containerBounds
            }
        } else {
            existingNode = tree.node(withID: tHit.nodeID)
            effectiveBounds = tHit.containerBounds
        }

        let draggedMin = SeamGeometry.minimumExtent(
            of: .window(id: 0, windowID: draggedWindowID),
            along: tHit.edge.axis,
            minSizes: minSizes
        )
        let containerMin = existingNode.map {
            SeamGeometry.minimumExtent(of: $0, along: tHit.edge.axis, minSizes: minSizes)
        } ?? SeamGeometry.defaultMinLeafDimension
        let length = effectiveBounds.span(along: tHit.edge.axis)
        let firstMin = tHit.edge.isFirstChild ? draggedMin : containerMin
        let secondMin = tHit.edge.isFirstChild ? containerMin : draggedMin
        return feasibleSplitRatio(parentLength: length, firstMinPx: firstMin, secondMinPx: secondMin)
    }

    private static func nodeBounds(of targetID: NodeID, in node: LayoutTree.Node, bounds: CGRect) -> CGRect? {
        if node.id == targetID { return bounds }
        guard case .split(_, let axis, let ratio, let first, let second) = node else { return nil }
        let (firstRect, secondRect, _) = bounds.splitFlush(axis: axis, ratio: ratio)
        return nodeBounds(of: targetID, in: first, bounds: firstRect)
            ?? nodeBounds(of: targetID, in: second, bounds: secondRect)
    }

    /// Simulates a same-space move + old-leaf collapse on a copy of `tree` to produce a WYSIWYG
    /// post-commit preview rect for `draggedWindowID`.
    private static func simulatedPreviewRect(
        tree: LayoutTree,
        draggedWindowID: WindowID,
        screenBounds: CGRect,
        fallback: CGRect,
        apply: (inout LayoutTree) -> Bool
    ) -> CGRect {
        guard let oldLeafID = tree.leafID(for: draggedWindowID) else {
            return fallback
        }
        var simulated = tree
        guard apply(&simulated) else { return fallback }
        simulated.removeLeafAndCollapse(leafID: oldLeafID)
        return simulated.windowFrames(in: screenBounds)[draggedWindowID] ?? fallback
    }

    /// Returns every edge whose band contains `point`, sorted from closest to farthest
    /// (normalized within its band).
    private static func edgeBandCandidates(
        point: CGPoint,
        in rect: CGRect,
        fraction: CGFloat,
        maxPixels: CGFloat
    ) -> [SplitEdge] {
        let bandX = min(rect.width * fraction, maxPixels)
        let bandY = min(rect.height * fraction, maxPixels)

        let dLeft = point.x - rect.minX
        let dRight = rect.maxX - point.x
        let dTop = point.y - rect.minY
        let dBottom = rect.maxY - point.y

        var candidates: [(SplitEdge, CGFloat)] = []
        if dLeft <= bandX, bandX > 0 { candidates.append((.left, dLeft / bandX)) }
        if dRight <= bandX, bandX > 0 { candidates.append((.right, dRight / bandX)) }
        if dTop <= bandY, bandY > 0 { candidates.append((.top, dTop / bandY)) }
        if dBottom <= bandY, bandY > 0 { candidates.append((.bottom, dBottom / bandY)) }

        return candidates.sorted(by: { $0.1 < $1.1 }).map(\.0)
    }

    /// Picks left/right/top/bottom using normalized distance from each edge (handles
    /// non-square cells cleanly without biasing toward horizontal or vertical splits).
    private static func nearestEdge(point: CGPoint, in rect: CGRect) -> SplitEdge {
        let nx = (point.x - rect.minX) / rect.width
        let ny = (point.y - rect.minY) / rect.height

        let distances: [(SplitEdge, CGFloat)] = [
            (.left, nx),
            (.right, 1 - nx),
            (.top, ny),
            (.bottom, 1 - ny),
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .right
    }

    private static func splitRect(of cell: CGRect, edge: SplitEdge, ratio: CGFloat = 0.5) -> CGRect {
        let (first, second, _) = cell.splitFlush(axis: edge.axis, ratio: ratio)
        return edge.isFirstChild ? first : second
    }

    // MARK: - Split T-junction detection

    private struct TJunctionCandidate {
        let nodeID: NodeID
        let edge: SplitEdge
        let containerBounds: CGRect
        let distance: CGFloat
        let depth: Int
    }

    private static func tJunctionHit(
        pointer: CGPoint,
        in root: LayoutTree.Node,
        bounds: CGRect
    ) -> TJunctionCandidate? {
        var best: TJunctionCandidate?
        collectTJunctions(node: root, bounds: bounds, depth: 0, pointer: pointer, best: &best)
        return best
    }

    private static func collectTJunctions(
        node: LayoutTree.Node,
        bounds: CGRect,
        depth: Int,
        pointer: CGPoint,
        best: inout TJunctionCandidate?
    ) {
        guard case .split(let id, let axis, let ratio, let first, let second) = node else { return }
        guard bounds.contains(pointer) else { return }

        let (firstRect, secondRect, seamPos) = bounds.splitFlush(axis: axis, ratio: ratio)

        // Only offer T-junction container splitting when both sides of the split are occupied
        // (or at least non-trivial); if one side is empty, normal empty-slot targeting is clearer.
        if !first.isCompletelyEmpty && !second.isCompletelyEmpty {
            let zones: [(edge: SplitEdge, rect: CGRect, anchor: CGPoint)]
            switch axis {
            case .vertical:
                let halfSpan = min(tJunctionHalfSpan, min(firstRect.width, secondRect.width) * 0.45)
                let depthPx = min(tJunctionMaxDepth, bounds.height * 0.14)
                let topRect = CGRect(x: seamPos - halfSpan, y: bounds.minY, width: halfSpan * 2, height: depthPx)
                let bottomRect = CGRect(x: seamPos - halfSpan, y: bounds.maxY - depthPx, width: halfSpan * 2, height: depthPx)
                zones = [
                    (.top, topRect, CGPoint(x: seamPos, y: bounds.minY)),
                    (.bottom, bottomRect, CGPoint(x: seamPos, y: bounds.maxY)),
                ]
            case .horizontal:
                let halfSpan = min(tJunctionHalfSpan, min(firstRect.height, secondRect.height) * 0.45)
                let depthPx = min(tJunctionMaxDepth, bounds.width * 0.14)
                let leftRect = CGRect(x: bounds.minX, y: seamPos - halfSpan, width: depthPx, height: halfSpan * 2)
                let rightRect = CGRect(x: bounds.maxX - depthPx, y: seamPos - halfSpan, width: depthPx, height: halfSpan * 2)
                zones = [
                    (.left, leftRect, CGPoint(x: bounds.minX, y: seamPos)),
                    (.right, rightRect, CGPoint(x: bounds.maxX, y: seamPos)),
                ]
            }

            for zone in zones where zone.rect.contains(pointer) {
                let dist = hypot(pointer.x - zone.anchor.x, pointer.y - zone.anchor.y)
                let candidate = TJunctionCandidate(
                    nodeID: id,
                    edge: zone.edge,
                    containerBounds: bounds,
                    distance: dist,
                    depth: depth
                )
                if let current = best {
                    if dist < current.distance - 1 || (abs(dist - current.distance) <= 1 && depth > current.depth) {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
            }
        }

        collectTJunctions(node: first, bounds: firstRect, depth: depth + 1, pointer: pointer, best: &best)
        collectTJunctions(node: second, bounds: secondRect, depth: depth + 1, pointer: pointer, best: &best)
    }
}
