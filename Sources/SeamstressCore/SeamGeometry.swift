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
    /// 10pt invisible hit strip along the flush seam.
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

/// Result of hit-testing a cursor point against visible seams.
public enum SeamHit: Equatable, Sendable {
    case single(VisibleSeam)
    /// Cursor sits at the junction of one or more vertical and horizontal seams (e.g. `┼` in
    /// a 2×2 grid where two horizontal splits meet a vertical split, or `├` in a 3-pane layout),
    /// allowing simultaneous 2-axis resizing of every seam meeting at that point.
    case intersection(verticals: [VisibleSeam], horizontals: [VisibleSeam])

    public var spaceKey: SpaceKey {
        switch self {
        case .single(let s): return s.spaceKey
        case .intersection(let vs, let hs): return (vs.first ?? hs.first)!.spaceKey
        }
    }

    public var participatingWindowIDs: Set<WindowID> {
        switch self {
        case .single(let s):
            return s.participatingWindowIDs
        case .intersection(let vs, let hs):
            var ids = Set<WindowID>()
            for s in vs { ids.formUnion(s.participatingWindowIDs) }
            for s in hs { ids.formUnion(s.participatingWindowIDs) }
            return ids
        }
    }

    public var allSeams: [VisibleSeam] {
        switch self {
        case .single(let s): return [s]
        case .intersection(let vs, let hs): return vs + hs
        }
    }

    public func contains(_ point: CGPoint) -> Bool {
        switch self {
        case .single(let s):
            return s.hitRect.contains(point)
        case .intersection(let vs, let hs):
            return vs.contains(where: { $0.hitRect.contains(point) })
                && hs.contains(where: { $0.hitRect.contains(point) })
        }
    }

    /// Stable identifier for change detection on hover.
    public var identityKey: String {
        switch self {
        case .single(let s):
            return "\(s.spaceKey):\(s.splitID)"
        case .intersection(let vs, let hs):
            let vIDs = vs.map { String($0.splitID) }.joined(separator: ",")
            let hIDs = hs.map { String($0.splitID) }.joined(separator: ",")
            return "\(spaceKey):v[\(vIDs)]+h[\(hIDs)]"
        }
    }
}

/// Magnetic snap feedback for a live seam drag.
public enum SeamSnapKind: Equatable, Sendable {
    case none
    case detent(CGFloat)
    case alignedSeam(CGFloat)
}

/// Result of computing a live seam drag update for a cursor position.
public struct SeamDragUpdate: Equatable, Sendable {
    public let ratio: CGFloat
    public let seamPosition: CGFloat
    public let visualRect: CGRect
    public let collapseTarget: SeamCollapseTarget
    public let isClamped: Bool
    public let snapKind: SeamSnapKind

    public init(
        ratio: CGFloat,
        seamPosition: CGFloat,
        visualRect: CGRect,
        collapseTarget: SeamCollapseTarget,
        isClamped: Bool = false,
        snapKind: SeamSnapKind = .none
    ) {
        self.ratio = ratio
        self.seamPosition = seamPosition
        self.visualRect = visualRect
        self.collapseTarget = collapseTarget
        self.isClamped = isClamped
        self.snapKind = snapKind
    }
}

public enum SeamGeometry {
    /// Total hit strip thickness in points (±5pt around the 0px seam).
    public static let hitThickness: CGFloat = 10
    /// Hairline visual indicator thickness in points.
    public static let visualThickness: CGFloat = 2
    /// Fallback minimum dimension per occupied leaf when app min size is unknown.
    public static let defaultMinLeafDimension: CGFloat = 140
    /// Minimum dimension reserved for an empty slot before clamping/collapsing.
    public static let minEmptySlotDimension: CGFloat = 48
    /// Dragging past 90% toward an empty side triggers collapse-on-release.
    public static let collapseThreshold: CGFloat = 0.90
    /// Magnetic snap tolerance in points for detents and co-linear seam alignment.
    public static let snapTolerancePoints: CGFloat = 7

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

    /// Hit-test `point` against a precomputed list of visible seams, returning either a
    /// single seam or a 2-axis intersection (`┼` / `├` / `┤` / `┬` / `┴`) collecting ALL
    /// vertical and horizontal seams whose hit strips meet at `point`.
    public static func hitTestTarget(point: CGPoint, seams: [VisibleSeam]) -> SeamHit? {
        var hitVerticals: [(seam: VisibleSeam, dist: CGFloat)] = []
        var hitHorizontals: [(seam: VisibleSeam, dist: CGFloat)] = []

        for seam in seams {
            // Extend cross-axis endpoints by half hitThickness so two seams meeting at a T or ┼
            // corner overlap cleanly in the 10×10pt junction box.
            let expandedHit = seam.hitRect.insetBy(dx: -hitThickness * 0.5, dy: -hitThickness * 0.5)
            guard expandedHit.contains(point) else { continue }
            let dist = abs(point.coordinate(along: seam.axis) - seam.seamPosition)
            guard dist <= hitThickness * 0.5 else { continue }
            switch seam.axis {
            case .vertical:
                hitVerticals.append((seam, dist))
            case .horizontal:
                hitHorizontals.append((seam, dist))
            }
        }

        hitVerticals.sort { $0.dist < $1.dist || ($0.dist == $1.dist && $0.seam.depth < $1.seam.depth) }
        hitHorizontals.sort { $0.dist < $1.dist || ($0.dist == $1.dist && $0.seam.depth < $1.seam.depth) }

        if let primaryV = hitVerticals.first?.seam,
           let primaryH = hitHorizontals.first?.seam,
           primaryV.spaceKey == primaryH.spaceKey {
            let space = primaryV.spaceKey
            let vs = hitVerticals.map(\.seam).filter { $0.spaceKey == space }
            let hs = hitHorizontals.map(\.seam).filter { $0.spaceKey == space }
            return .intersection(verticals: vs, horizontals: hs)
        }
        if let v = hitVerticals.first?.seam, v.hitRect.contains(point) { return .single(v) }
        if let h = hitHorizontals.first?.seam, h.hitRect.contains(point) { return .single(h) }
        return nil
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
                return max(size.span(along: axis), defaultMinLeafDimension)
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

    /// Compute the clamped ratio, hairline rect, snap feedback, and collapse state for a live seam drag.
    public static func dragUpdate(
        pointer: CGPoint,
        seam: VisibleSeam,
        tree: LayoutTree,
        minSizes: [WindowID: CGSize],
        allSeams: [VisibleSeam] = [],
        disableSnapping: Bool = false,
        grabOffset: CGFloat = 0
    ) -> SeamDragUpdate {
        let parentStart = seam.parentBounds.start(along: seam.axis)
        let parentLength = seam.parentBounds.span(along: seam.axis)
        let cursorCoord = pointer.coordinate(along: seam.axis)

        guard parentLength > 1 else {
            return SeamDragUpdate(
                ratio: seam.ratio,
                seamPosition: seam.seamPosition,
                visualRect: seam.visualRect,
                collapseTarget: .none
            )
        }

        let adjustedCursorCoord = cursorCoord - grabOffset
        let rawRatio = (adjustedCursorCoord - parentStart) / parentLength

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

        // Apply magnetic snapping (co-linear sibling seams first, then ratio detents)
        var desiredRatio = rawRatio
        var snapKind: SeamSnapKind = .none

        if !disableSnapping {
            let parentEnd = parentStart + parentLength
            var bestAligned: (position: CGFloat, dist: CGFloat)?
            for other in allSeams {
                guard other.spaceKey == seam.spaceKey,
                      other.axis == seam.axis,
                      other.splitID != seam.splitID,
                      other.seamPosition > parentStart,
                      other.seamPosition < parentEnd else {
                    continue
                }
                let dist = abs(other.seamPosition - adjustedCursorCoord)
                if dist <= snapTolerancePoints {
                    if bestAligned == nil || dist < bestAligned!.dist {
                        bestAligned = (other.seamPosition, dist)
                    }
                }
            }

            if let aligned = bestAligned {
                desiredRatio = (aligned.position - parentStart) / parentLength
                snapKind = .alignedSeam(aligned.position)
            } else {
                let detents: [CGFloat] = [0.5, 1.0 / 3.0, 2.0 / 3.0]
                for d in detents {
                    let detentPos = parentStart + d * parentLength
                    if abs(detentPos - adjustedCursorCoord) <= snapTolerancePoints {
                        desiredRatio = d
                        snapKind = .detent(d)
                        break
                    }
                }
            }
        }

        // Compute safe ratio bounds from subtree minimum extents
        var minRatio: CGFloat = 0.08
        var maxRatio: CGFloat = 0.92

        if let splitNode = tree.node(withID: seam.splitID),
           case .split(_, _, _, let first, let second) = splitNode {
            let firstMinPx = first.isCompletelyEmpty ? minEmptySlotDimension : minimumExtent(of: first, along: seam.axis, minSizes: minSizes)
            let secondMinPx = second.isCompletelyEmpty ? minEmptySlotDimension : minimumExtent(of: second, along: seam.axis, minSizes: minSizes)

            let computedMin = firstMinPx / parentLength
            let computedMax = 1.0 - (secondMinPx / parentLength)

            if computedMin <= computedMax {
                minRatio = max(0.05, computedMin)
                maxRatio = min(0.95, computedMax)
            } else if second.isCompletelyEmpty && !first.isCompletelyEmpty {
                // Occupied first side exceeds available space next to an empty slot: allow
                // dragging toward the empty side to expand/collapse instead of freezing.
                minRatio = min(seam.ratio, 0.95)
                maxRatio = 0.95
            } else if first.isCompletelyEmpty && !second.isCompletelyEmpty {
                // Occupied second side exceeds available space next to an empty slot: allow
                // dragging toward the empty side to expand/collapse instead of freezing.
                minRatio = 0.05
                maxRatio = max(seam.ratio, 0.05)
            } else {
                // Both occupied sides want more than available space; hold current ratio safely.
                minRatio = seam.ratio
                maxRatio = seam.ratio
            }
        }

        let clampedRatio = min(max(desiredRatio, minRatio), maxRatio)
        let isClamped = abs(clampedRatio - desiredRatio) > 0.002
        if isClamped {
            switch snapKind {
            case .none:
                break
            case .detent(let d):
                if abs(clampedRatio - d) > 0.002 {
                    snapKind = .none
                }
            case .alignedSeam(let pos):
                let snapRatio = (pos - parentStart) / parentLength
                if abs(clampedRatio - snapRatio) > 0.002 {
                    snapKind = .none
                }
            }
        }

        let (_, _, seamPos) = seam.parentBounds.splitFlush(axis: seam.axis, ratio: clampedRatio)
        return SeamDragUpdate(
            ratio: clampedRatio,
            seamPosition: seamPos,
            visualRect: visualRect(axis: seam.axis, parentBounds: seam.parentBounds, seamPosition: seamPos),
            collapseTarget: .none,
            isClamped: isClamped,
            snapKind: snapKind
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
}
