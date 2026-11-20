import CoreGraphics
import Foundation

public typealias NodeID = UInt64

/// A leaf cell in a BSP layout tree, along with its resolved frame in CG coordinates.
public struct LeafPlacement: Equatable, Sendable {
    public let leafID: NodeID
    public let windowID: WindowID?
    public let frame: CGRect

    public var isEmpty: Bool { windowID == nil }

    public init(leafID: NodeID, windowID: WindowID?, frame: CGRect) {
        self.leafID = leafID
        self.windowID = windowID
        self.frame = frame
    }
}

/// Binary Space Partitioning tree with persistent empty slots.
///
/// Invariants:
/// - Every `.split` node has at least one non-empty descendant; if both children become
///   empty, the split collapses upward into a single `.empty` leaf.
/// - Every `WindowID` appears at most once in a tree.
/// - Every node in a tree has a unique `NodeID`.
public struct LayoutTree: Equatable, Sendable {
    public indirect enum Node: Equatable, Sendable {
        case empty(id: NodeID)
        case window(id: NodeID, windowID: WindowID)
        case split(id: NodeID, axis: SplitAxis, ratio: CGFloat, first: Node, second: Node)

        public var id: NodeID {
            switch self {
            case .empty(let id): return id
            case .window(let id, _): return id
            case .split(let id, _, _, _, _): return id
            }
        }

        public var isCompletelyEmpty: Bool {
            switch self {
            case .empty: return true
            case .window: return false
            case .split(_, _, _, let first, let second):
                return first.isCompletelyEmpty && second.isCompletelyEmpty
            }
        }

        public func windowIDs() -> [WindowID] {
            switch self {
            case .empty:
                return []
            case .window(_, let wid):
                return [wid]
            case .split(_, _, _, let first, let second):
                return first.windowIDs() + second.windowIDs()
            }
        }
    }

    public private(set) var root: Node
    private var nextID: NodeID

    public init() {
        self.root = .empty(id: 1)
        self.nextID = 2
    }

    internal init(root: Node, nextID: NodeID) {
        self.root = root
        self.nextID = nextID
    }

    private mutating func allocID() -> NodeID {
        defer { nextID += 1 }
        return nextID
    }

    public var isEmpty: Bool { root.isCompletelyEmpty }

    public var allWindowIDs: [WindowID] { root.windowIDs() }

    public func contains(windowID: WindowID) -> Bool {
        findLeafID(for: windowID, in: root) != nil
    }

    public func leafID(for windowID: WindowID) -> NodeID? {
        findLeafID(for: windowID, in: root)
    }

    private func findLeafID(for windowID: WindowID, in node: Node) -> NodeID? {
        switch node {
        case .empty:
            return nil
        case .window(let id, let wid):
            return wid == windowID ? id : nil
        case .split(_, _, _, let first, let second):
            return findLeafID(for: windowID, in: first) ?? findLeafID(for: windowID, in: second)
        }
    }

    // MARK: - Frame resolution

    public func leafPlacements(in bounds: CGRect) -> [LeafPlacement] {
        var result: [LeafPlacement] = []
        collectLeaves(node: root, bounds: bounds, into: &result)
        return result
    }

    public func windowFrames(in bounds: CGRect) -> [WindowID: CGRect] {
        var result: [WindowID: CGRect] = [:]
        collectWindowFrames(node: root, bounds: bounds, into: &result)
        return result
    }

    public func leaf(at point: CGPoint, in bounds: CGRect) -> LeafPlacement? {
        guard bounds.contains(point) else { return nil }
        return findLeaf(at: point, node: root, bounds: bounds)
    }

    private func collectLeaves(node: Node, bounds: CGRect, into result: inout [LeafPlacement]) {
        switch node {
        case .empty(let id):
            result.append(LeafPlacement(leafID: id, windowID: nil, frame: bounds))
        case .window(let id, let wid):
            result.append(LeafPlacement(leafID: id, windowID: wid, frame: bounds))
        case .split(_, let axis, let ratio, let first, let second):
            let (firstRect, secondRect, _) = bounds.splitFlush(axis: axis, ratio: ratio)
            collectLeaves(node: first, bounds: firstRect, into: &result)
            collectLeaves(node: second, bounds: secondRect, into: &result)
        }
    }

    private func collectWindowFrames(node: Node, bounds: CGRect, into result: inout [WindowID: CGRect]) {
        switch node {
        case .empty:
            return
        case .window(_, let wid):
            result[wid] = bounds
        case .split(_, let axis, let ratio, let first, let second):
            let (firstRect, secondRect, _) = bounds.splitFlush(axis: axis, ratio: ratio)
            collectWindowFrames(node: first, bounds: firstRect, into: &result)
            collectWindowFrames(node: second, bounds: secondRect, into: &result)
        }
    }

    private func findLeaf(at point: CGPoint, node: Node, bounds: CGRect) -> LeafPlacement {
        switch node {
        case .empty(let id):
            return LeafPlacement(leafID: id, windowID: nil, frame: bounds)
        case .window(let id, let wid):
            return LeafPlacement(leafID: id, windowID: wid, frame: bounds)
        case .split(_, let axis, let ratio, let first, let second):
            let (firstRect, secondRect, seamPos) = bounds.splitFlush(axis: axis, ratio: ratio)
            let goFirst: Bool
            switch axis {
            case .vertical: goFirst = point.x < seamPos
            case .horizontal: goFirst = point.y < seamPos
            }
            if goFirst {
                return findLeaf(at: point, node: first, bounds: firstRect)
            } else {
                return findLeaf(at: point, node: second, bounds: secondRect)
            }
        }
    }

    // MARK: - Mutations

    /// Fill an existing empty leaf with `windowID`. Returns true if applied.
    @discardableResult
    public mutating func fillEmpty(leafID: NodeID, with windowID: WindowID) -> Bool {
        var applied = false
        root = mapNode(root) { node in
            guard case .empty(let id) = node, id == leafID else { return node }
            applied = true
            return .window(id: id, windowID: windowID)
        }
        return applied
    }

    /// Split an empty leaf 50/50 along `edge`, placing `windowID` on `edge`'s half
    /// and leaving the opposite half `.empty`.
    @discardableResult
    public mutating func splitEmpty(leafID: NodeID, edge: SplitEdge, with windowID: WindowID) -> Bool {
        var applied = false
        let splitID = allocID()
        let winLeafID = allocID()
        let emptyLeafID = allocID()
        root = mapNode(root) { node in
            guard case .empty(let id) = node, id == leafID else { return node }
            applied = true
            let winNode: Node = .window(id: winLeafID, windowID: windowID)
            let emptyNode: Node = .empty(id: emptyLeafID)
            if edge.isFirstChild {
                return .split(id: splitID, axis: edge.axis, ratio: 0.5, first: winNode, second: emptyNode)
            } else {
                return .split(id: splitID, axis: edge.axis, ratio: 0.5, first: emptyNode, second: winNode)
            }
        }
        return applied
    }

    /// Split an occupied leaf 50/50 along `edge`, placing `incomingWindowID` on `edge`'s half
    /// and keeping the existing window on the opposite half.
    @discardableResult
    public mutating func splitOccupied(leafID: NodeID, edge: SplitEdge, with incomingWindowID: WindowID) -> Bool {
        var applied = false
        let splitID = allocID()
        let newLeafID = allocID()
        root = mapNode(root) { node in
            guard case .window(let id, let existing) = node, id == leafID else { return node }
            applied = true
            let existingNode: Node = .window(id: id, windowID: existing)
            let incomingNode: Node = .window(id: newLeafID, windowID: incomingWindowID)
            if edge.isFirstChild {
                return .split(id: splitID, axis: edge.axis, ratio: 0.5, first: incomingNode, second: existingNode)
            } else {
                return .split(id: splitID, axis: edge.axis, ratio: 0.5, first: existingNode, second: incomingNode)
            }
        }
        return applied
    }

    /// Shrink an occupied leaf to `edge`'s half of its own slot, leaving the other half `.empty`.
    @discardableResult
    public mutating func shrinkToEdge(leafID: NodeID, edge: SplitEdge) -> Bool {
        var applied = false
        let splitID = allocID()
        let emptyLeafID = allocID()
        root = mapNode(root) { node in
            guard case .window(let id, let wid) = node, id == leafID else { return node }
            applied = true
            let winNode: Node = .window(id: id, windowID: wid)
            let emptyNode: Node = .empty(id: emptyLeafID)
            if edge.isFirstChild {
                return .split(id: splitID, axis: edge.axis, ratio: 0.5, first: winNode, second: emptyNode)
            } else {
                return .split(id: splitID, axis: edge.axis, ratio: 0.5, first: emptyNode, second: winNode)
            }
        }
        return applied
    }

    /// Swap two tiled windows already present in this tree.
    @discardableResult
    public mutating func swapWindows(_ a: WindowID, _ b: WindowID) -> Bool {
        guard a != b, contains(windowID: a), contains(windowID: b) else { return false }
        root = mapNode(root) { node in
            guard case .window(let id, let wid) = node else { return node }
            if wid == a { return .window(id: id, windowID: b) }
            if wid == b { return .window(id: id, windowID: a) }
            return node
        }
        return true
    }

    /// Replace the window in `leafID` with `incoming`, returning the displaced window (if any).
    @discardableResult
    public mutating func replaceWindow(at leafID: NodeID, with incoming: WindowID) -> WindowID? {
        var displaced: WindowID?
        root = mapNode(root) { node in
            guard case .window(let id, let existing) = node, id == leafID else { return node }
            displaced = existing
            return .window(id: id, windowID: incoming)
        }
        return displaced
    }

    /// Remove `windowID`, leaving its slot `.empty` and collapsing any `.split` whose
    /// children are both completely empty.
    @discardableResult
    public mutating func removeWindow(_ windowID: WindowID) -> Bool {
        guard let id = leafID(for: windowID) else { return false }
        return removeLeaf(leafID: id)
    }

    /// Replace the leaf with `leafID` by `.empty` and collapse any double-empty splits upward.
    @discardableResult
    public mutating func removeLeaf(leafID: NodeID) -> Bool {
        var removed = false
        let replaced = mapNode(root) { node in
            guard case .window(let id, _) = node, id == leafID else { return node }
            removed = true
            return .empty(id: id)
        }
        guard removed else { return false }
        root = collapseDoubleEmpty(replaced)
        return true
    }

    /// Remove `windowID` and immediately promote its sibling to fill the vacated space.
    /// If `windowID` was the only leaf in the tree, resets to an empty root.
    @discardableResult
    public mutating func removeWindowAndCollapse(_ windowID: WindowID) -> Bool {
        guard contains(windowID: windowID) else { return false }
        if let collapsed = pruneWindow(windowID, in: root) {
            root = collapseDoubleEmpty(collapsed)
        } else {
            root = .empty(id: allocID())
        }
        return true
    }

    private func pruneWindow(_ target: WindowID, in node: Node) -> Node? {
        switch node {
        case .empty:
            return node
        case .window(_, let wid):
            return wid == target ? nil : node
        case .split(let id, let axis, let ratio, let first, let second):
            let newFirst = pruneWindow(target, in: first)
            let newSecond = pruneWindow(target, in: second)
            switch (newFirst, newSecond) {
            case (nil, nil):
                return nil
            case (let surviving?, nil):
                return surviving
            case (nil, let surviving?):
                return surviving
            case (let f?, let s?):
                return .split(id: id, axis: axis, ratio: ratio, first: f, second: s)
            }
        }
    }

    /// Update the split ratio for `splitID`.
    @discardableResult
    public mutating func setRatio(splitID: NodeID, ratio: CGFloat) -> Bool {
        let clamped = min(max(ratio, 0.05), 0.95)
        var updated = false
        root = mapNode(root) { node in
            guard case .split(let id, let axis, _, let first, let second) = node, id == splitID else {
                return node
            }
            updated = true
            return .split(id: id, axis: axis, ratio: clamped, first: first, second: second)
        }
        return updated
    }

    /// If one child of `splitID` is completely empty, replace `splitID` with its non-empty sibling.
    /// Returns true if collapsed.
    @discardableResult
    public mutating func collapseEmptyChild(splitID: NodeID) -> Bool {
        var collapsed = false
        root = mapNode(root) { node in
            guard case .split(let id, _, _, let first, let second) = node, id == splitID else {
                return node
            }
            if first.isCompletelyEmpty && !second.isCompletelyEmpty {
                collapsed = true
                return second
            }
            if second.isCompletelyEmpty && !first.isCompletelyEmpty {
                collapsed = true
                return first
            }
            return node
        }
        if collapsed {
            root = collapseDoubleEmpty(root)
        }
        return collapsed
    }

    /// Double-click behavior on a seam:
    /// - If either side of `splitID` is completely empty, collapse the empty side.
    /// - Otherwise reset the split ratio to 0.5.
    @discardableResult
    public mutating func handleSeamDoubleClick(splitID: NodeID) -> Bool {
        if collapseEmptyChild(splitID: splitID) {
            return true
        }
        return setRatio(splitID: splitID, ratio: 0.5)
    }

    // MARK: - Helpers

    private func mapNode(_ node: Node, transform: (Node) -> Node) -> Node {
        switch node {
        case .empty, .window:
            return transform(node)
        case .split(let id, let axis, let ratio, let first, let second):
            let newFirst = mapNode(first, transform: transform)
            let newSecond = mapNode(second, transform: transform)
            return transform(.split(id: id, axis: axis, ratio: ratio, first: newFirst, second: newSecond))
        }
    }

    private func collapseDoubleEmpty(_ node: Node) -> Node {
        switch node {
        case .empty, .window:
            return node
        case .split(let id, let axis, let ratio, let first, let second):
            let cFirst = collapseDoubleEmpty(first)
            let cSecond = collapseDoubleEmpty(second)
            if cFirst.isCompletelyEmpty && cSecond.isCompletelyEmpty {
                return .empty(id: id)
            }
            return .split(id: id, axis: axis, ratio: ratio, first: cFirst, second: cSecond)
        }
    }
}
