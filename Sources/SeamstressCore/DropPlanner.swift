import CoreGraphics
import Foundation

/// Visual style hint for the drop preview overlay.
public enum DropPreviewKind: Equatable, Sendable {
    case fill
    case split
    case swap
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

    public init(targetSpace: SpaceKey, action: Action, previewRect: CGRect, previewKind: DropPreviewKind) {
        self.targetSpace = targetSpace
        self.action = action
        self.previewRect = previewRect
        self.previewKind = previewKind
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

    public static func plan(
        pointer: CGPoint,
        draggedWindowID: WindowID,
        targetSpace: SpaceKey,
        tree: LayoutTree,
        screenBounds: CGRect
    ) -> DropPlan? {
        guard let leaf = tree.leaf(at: pointer, in: screenBounds) else {
            return nil
        }

        let cell = leaf.frame
        guard cell.width > 1, cell.height > 1 else { return nil }

        // Case 1: Empty space (either empty screen or empty BSP slot)
        if leaf.isEmpty {
            if let edge = edgeBandHit(point: pointer, in: cell, fraction: emptyEdgeFraction, maxPixels: maxEmptyEdgePixels) {
                let preview = halfRect(of: cell, edge: edge)
                return DropPlan(
                    targetSpace: targetSpace,
                    action: .splitEmpty(leafID: leaf.leafID, edge: edge),
                    previewRect: preview,
                    previewKind: .split
                )
            } else {
                return DropPlan(
                    targetSpace: targetSpace,
                    action: .fillEmpty(leafID: leaf.leafID),
                    previewRect: cell,
                    previewKind: .fill
                )
            }
        }

        guard let occupant = leaf.windowID else { return nil }

        // Case 2: Dragging a tiled window over its own slot
        if occupant == draggedWindowID {
            if let edge = edgeBandHit(point: pointer, in: cell, fraction: emptyEdgeFraction, maxPixels: maxEmptyEdgePixels) {
                let preview = halfRect(of: cell, edge: edge)
                return DropPlan(
                    targetSpace: targetSpace,
                    action: .shrinkOwnSlot(leafID: leaf.leafID, edge: edge),
                    previewRect: preview,
                    previewKind: .split
                )
            } else {
                return DropPlan(
                    targetSpace: targetSpace,
                    action: .keepInPlace(leafID: leaf.leafID),
                    previewRect: cell,
                    previewKind: .fill
                )
            }
        }

        // Case 3: Occupied slot belonging to another window
        let centerInsetX = cell.width * (1 - occupiedCenterFraction) * 0.5
        let centerInsetY = cell.height * (1 - occupiedCenterFraction) * 0.5
        let centerRect = cell.insetBy(dx: centerInsetX, dy: centerInsetY)

        if centerRect.contains(pointer) {
            return DropPlan(
                targetSpace: targetSpace,
                action: .swapOrReplace(leafID: leaf.leafID, targetWindowID: occupant),
                previewRect: cell,
                previewKind: .swap
            )
        }

        let edge = nearestEdge(point: pointer, in: cell)
        let preview = halfRect(of: cell, edge: edge)
        return DropPlan(
            targetSpace: targetSpace,
            action: .splitOccupied(leafID: leaf.leafID, edge: edge),
            previewRect: preview,
            previewKind: .split
        )
    }

    /// Returns the closest edge if `point` lies inside one of the four edge bands of `rect`,
    /// or `nil` if `point` is in the interior.
    private static func edgeBandHit(
        point: CGPoint,
        in rect: CGRect,
        fraction: CGFloat,
        maxPixels: CGFloat
    ) -> SplitEdge? {
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

        return candidates.min(by: { $0.1 < $1.1 })?.0
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

    private static func halfRect(of cell: CGRect, edge: SplitEdge) -> CGRect {
        let (first, second, _) = cell.splitFlush(axis: edge.axis, ratio: 0.5)
        return edge.isFirstChild ? first : second
    }
}
