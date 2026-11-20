import CoreGraphics
import Foundation

/// Collapse action when dragging a seam past the edge threshold into an empty slot.
public enum SeamCollapseTarget: Equatable, Sendable {
    case none
    /// First child is empty and user dragged past the start threshold -> expand second child.
    case collapseFirst(expandedBounds: CGRect)
    /// Second child is empty and user dragged past the end threshold -> expand first child.
    case collapseSecond(expandedBounds: CGRect)
}

/// Geometry and metadata for a single draggable flush seam in a BSP tree.
public struct VisibleSeam: Equatable, Sendable {
    public let splitID: NodeID
    public let spaceKey: SpaceKey
    public let axis: SplitAxis
    public let parentBounds: CGRect
    public let ratio: CGFloat
    /// Pixel coordinate along the split axis (X for vertical, Y for horizontal).
    public let seamPosition: CGFloat
    /// 8pt invisible hit strip along the flush seam.
    public let hitRect: CGRect
    /// 2pt hairline visual rect along the seam.
    public let visualRect: CGRect
    public let firstIsEmpty: Bool
    public let secondIsEmpty: Bool
    /// Windows bordering this split (used to check Z-order occlusion against floating windows).
    public let participatingWindowIDs: Set<WindowID>
    /// Depth in the tree (deeper seams win tie-breaks at T-junctions if closer, or exact containment).
    public let depth: Int

    public init(
        splitID: NodeID,
        spaceKey: SpaceKey,
        axis: SplitAxis,
        parentBounds: CGRect,
        ratio: CGFloat,
        seamPosition: CGFloat,
        hitRect: CGRect,
        visualRect: CGRect,
        firstIsEmpty: Bool,
        secondIsEmpty: Bool,
        participatingWindowIDs: Set<WindowID>,
        depth: Int
    ) {
        self.splitID = splitID
        self.spaceKey = spaceKey
        self.axis = axis
        self.parentBounds = parentBounds
        self.ratio = ratio
        self.seamPosition = seamPosition
        self.hitRect = hitRect
        self.visualRect = visualRect
        self.firstIsEmpty = firstIsEmpty
        self.secondIsEmpty = secondIsEmpty
        self.participatingWindowIDs = participatingWindowIDs
        self.depth = depth
    }
}

/// Result of computing a live seam drag update for a cursor position.
public struct SeamDragUpdate: Equatable, Sendable {
    public let ratio: CGFloat
    public let seamPosition: CGFloat
    public let visualRect: CGRect
    public let collapseTarget: SeamCollapseTarget
}

public enum SeamGeometry {
    /// Total hit strip thickness in points (±5pt around the 0px seam).
    public static let hitThickness: CGFloat = 10
    /// Hairline visual indicator thickness in points.
    public static let visualThickness: CGFloat = 2
    /// Fallback minimum dimension per occupied leaf when app min size is unknown.
    public static let defaultMinLeafDimension: CGFloat = 140
    /// Dragging past 90% toward an empty side triggers collapse-on-release.
    public static let collapseThreshold: CGFloat = 0.90

    /// Extract all visible draggable seams from `tree` in `bounds`.
    public static func seams(in tree: LayoutTree, spaceKey: SpaceKey, bounds: CGRect) -> [VisibleSeam] {
        var result: [VisibleSeam] = []
        collect(node: tree.root, spaceKey: spaceKey, bounds: bounds, depth: 0, into: &result)
        return result
    }

    private static func collect(
        node: LayoutTree.Node,
        spaceKey: SpaceKey,
        bounds: CGRect,
        depth: Int,
        into result: inout [VisibleSeam]
    ) {
        guard case .split(let id, let axis, let ratio, let first, let second) = node else { return }
        let (firstRect, secondRect, seamPos) = bounds.splitFlush(axis: axis, ratio: ratio)
        let halfHit = hitThickness * 0.5
        let halfVis = visualThickness * 0.5

        let hitRect: CGRect
        let visualRect: CGRect
        switch axis {
        case .vertical:
            hitRect = CGRect(x: seamPos - halfHit, y: bounds.minY, width: hitThickness, height: bounds.height)
            visualRect = CGRect(x: seamPos - halfVis, y: bounds.minY, width: visualThickness, height: bounds.height)
        case .horizontal:
            hitRect = CGRect(x: bounds.minX, y: seamPos - halfHit, width: bounds.width, height: hitThickness)
            visualRect = CGRect(x: bounds.minX, y: seamPos - halfVis, width: bounds.width, height: visualThickness)
        }

        let windows = Set(first.windowIDs() + second.windowIDs())
        result.append(VisibleSeam(
            splitID: id,
            spaceKey: spaceKey,
            axis: axis,
            parentBounds: bounds,
            ratio: ratio,
            seamPosition: seamPos,
            hitRect: hitRect,
            visualRect: visualRect,
            firstIsEmpty: first.isCompletelyEmpty,
            secondIsEmpty: second.isCompletelyEmpty,
            participatingWindowIDs: windows,
            depth: depth
        ))

        collect(node: first, spaceKey: spaceKey, bounds: firstRect, depth: depth + 1, into: &result)
        collect(node: second, spaceKey: spaceKey, bounds: secondRect, depth: depth + 1, into: &result)
    }

    /// Hit-test `point` against a precomputed list of visible seams.
    /// Prefers the seam whose center line is closest to `point` (and shallower/longer seams on exact ties).
    public static func hitTest(point: CGPoint, seams: [VisibleSeam]) -> VisibleSeam? {
        var best: VisibleSeam?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for seam in seams {
            guard seam.hitRect.contains(point) else { continue }
            let dist: CGFloat
            switch seam.axis {
            case .vertical: dist = abs(point.x - seam.seamPosition)
            case .horizontal: dist = abs(point.y - seam.seamPosition)
            }
            if dist < bestDist || (dist == bestDist && (best == nil || seam.depth < best!.depth)) {
                best = seam
                bestDist = dist
            }
        }
        return best
    }

    /// Minimum pixel extent required by `node` along `axis`, accounting for known app min sizes.
    public static func minimumExtent(
        of node: LayoutTree.Node,
        along axis: SplitAxis,
        minSizes: [WindowID: CGSize]
    ) -> CGFloat {
        switch node {
        case .empty:
            return 0
        case .window(_, let wid):
            if let size = minSizes[wid] {
                let d = axis == .vertical ? size.width : size.height
                return max(d, defaultMinLeafDimension)
            }
            return defaultMinLeafDimension
        case .split(_, let childAxis, _, let first, let second):
            let firstMin = minimumExtent(of: first, along: axis, minSizes: minSizes)
            let secondMin = minimumExtent(of: second, along: axis, minSizes: minSizes)
            if childAxis == axis {
                return firstMin + secondMin
            } else {
                return max(firstMin, secondMin)
            }
        }
    }

    /// Compute the clamped ratio, hairline rect, and collapse state for a live seam drag.
    public static func dragUpdate(
        pointer: CGPoint,
        seam: VisibleSeam,
        tree: LayoutTree,
        minSizes: [WindowID: CGSize]
    ) -> SeamDragUpdate {
        let parentStart: CGFloat
        let parentLength: CGFloat
        let cursorCoord: CGFloat

        switch seam.axis {
        case .vertical:
            parentStart = seam.parentBounds.minX
            parentLength = seam.parentBounds.width
            cursorCoord = pointer.x
        case .horizontal:
            parentStart = seam.parentBounds.minY
            parentLength = seam.parentBounds.height
            cursorCoord = pointer.y
        }

        guard parentLength > 1 else {
            return SeamDragUpdate(
                ratio: seam.ratio,
                seamPosition: seam.seamPosition,
                visualRect: seam.visualRect,
                collapseTarget: .none
            )
        }

        let rawRatio = (cursorCoord - parentStart) / parentLength

        // Check collapse threshold toward an empty child before clamping
        if seam.firstIsEmpty && rawRatio <= (1.0 - collapseThreshold) {
            return SeamDragUpdate(
                ratio: seam.ratio,
                seamPosition: parentStart,
                visualRect: visualRect(axis: seam.axis, parentBounds: seam.parentBounds, seamPosition: parentStart),
                collapseTarget: .collapseFirst(expandedBounds: seam.parentBounds)
            )
        }
        if seam.secondIsEmpty && rawRatio >= collapseThreshold {
            let endPos = parentStart + parentLength
            return SeamDragUpdate(
                ratio: seam.ratio,
                seamPosition: endPos,
                visualRect: visualRect(axis: seam.axis, parentBounds: seam.parentBounds, seamPosition: endPos),
                collapseTarget: .collapseSecond(expandedBounds: seam.parentBounds)
            )
        }

        // Compute safe ratio bounds from subtree minimum extents
        var minRatio: CGFloat = 0.08
        var maxRatio: CGFloat = 0.92

        if let splitNode = findSplit(id: seam.splitID, in: tree.root),
           case .split(_, _, _, let first, let second) = splitNode {
            let firstMinPx = first.isCompletelyEmpty ? 48 : minimumExtent(of: first, along: seam.axis, minSizes: minSizes)
            let secondMinPx = second.isCompletelyEmpty ? 48 : minimumExtent(of: second, along: seam.axis, minSizes: minSizes)

            let computedMin = firstMinPx / parentLength
            let computedMax = 1.0 - (secondMinPx / parentLength)

            if computedMin <= computedMax {
                minRatio = max(0.05, computedMin)
                maxRatio = min(0.95, computedMax)
            } else {
                // Both sides want more than available space; hold current ratio safely.
                minRatio = seam.ratio
                maxRatio = seam.ratio
            }
        }

        let clampedRatio = min(max(rawRatio, minRatio), maxRatio)
        let (_, _, seamPos) = seam.parentBounds.splitFlush(axis: seam.axis, ratio: clampedRatio)
        return SeamDragUpdate(
            ratio: clampedRatio,
            seamPosition: seamPos,
            visualRect: visualRect(axis: seam.axis, parentBounds: seam.parentBounds, seamPosition: seamPos),
            collapseTarget: .none
        )
    }

    private static func visualRect(axis: SplitAxis, parentBounds: CGRect, seamPosition: CGFloat) -> CGRect {
        let halfVis = visualThickness * 0.5
        switch axis {
        case .vertical:
            return CGRect(x: seamPosition - halfVis, y: parentBounds.minY, width: visualThickness, height: parentBounds.height)
        case .horizontal:
            return CGRect(x: parentBounds.minX, y: seamPosition - halfVis, width: parentBounds.width, height: visualThickness)
        }
    }

    private static func findSplit(id: NodeID, in node: LayoutTree.Node) -> LayoutTree.Node? {
        switch node {
        case .empty, .window:
            return nil
        case .split(let nodeID, _, _, let first, let second):
            if nodeID == id { return node }
            return findSplit(id: id, in: first) ?? findSplit(id: id, in: second)
        }
    }
}
