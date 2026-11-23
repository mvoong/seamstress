import CoreGraphics
import Foundation

/// Input window geometry for startup layout reconstruction.
public struct WindowCandidate: Equatable, Sendable {
    public let windowID: WindowID
    public let frame: CGRect

    public init(windowID: WindowID, frame: CGRect) {
        self.windowID = windowID
        self.frame = frame
    }
}

/// Pure BSP layout reconstructor that detects existing flush-tiled window arrangements
/// on app launch (or first visit to a Space) and converts them back into a `LayoutTree`
/// with their exact split ratios, while ignoring floating windows.
public enum LayoutReconstructor {
    /// Edge alignment tolerance in points (absorbs terminal cell rounding and minor chrome offsets).
    public static let defaultTolerance: CGFloat = 14
    /// Maximum recursion depth to keep reconstruction bounded and instantaneous.
    public static let maxDepth: Int = 5

    public static func reconstruct(
        windows: [WindowCandidate],
        in bounds: CGRect,
        tolerance: CGFloat = defaultTolerance
    ) -> LayoutTree? {
        guard bounds.width >= 200, bounds.height >= 200 else { return nil }

        // Keep only windows that sit substantially inside `bounds` and are large enough to be tiles.
        var eligible = windows.filter { w in
            w.frame.width >= 100 &&
            w.frame.height >= 100 &&
            w.frame.minX >= bounds.minX - tolerance &&
            w.frame.maxX <= bounds.maxX + tolerance &&
            w.frame.minY >= bounds.minY - tolerance &&
            w.frame.maxY <= bounds.maxY + tolerance
        }
        guard !eligible.isEmpty else { return nil }

        // Iteratively solve and prune any adopted window that has fewer than 3 anchored edges
        // (touching the screen boundary or another adopted window). This prevents floating windows
        // sitting in an empty region (e.g. tucked in a corner or centered vertically) from being
        // falsely adopted by carving empty strips around them.
        var nextID: NodeID = 1
        var best: Solution
        while true {
            nextID = 1
            func allocID() -> NodeID {
                defer { nextID += 1 }
                return nextID
            }

            best = solve(
                region: bounds,
                candidates: eligible,
                depth: 0,
                tolerance: tolerance,
                allocID: allocID
            )

            guard best.windowCount > 0 else { return nil }

            let adoptedIDs = Set(best.node.windowIDs())
            let adoptedCandidates = eligible.filter { adoptedIDs.contains($0.windowID) }
            let unanchoredIDs = Set(adoptedCandidates.compactMap { candidate in
                anchoredEdgeCount(
                    for: candidate,
                    among: adoptedCandidates,
                    in: bounds,
                    tolerance: tolerance
                ) < 3 ? candidate.windowID : nil
            })
            if unanchoredIDs.isEmpty {
                break
            }
            eligible.removeAll { unanchoredIDs.contains($0.windowID) }
            guard !eligible.isEmpty else { return nil }
        }

        let totalArea = bounds.width * bounds.height
        let coverage = best.coveredArea / totalArea

        // Guardrails against falsely adopting ordinary floating windows:
        // - 2+ matched flush windows covering >= 50% of the screen -> unmistakably tiled.
        // - 1 matched window covering >= 85% -> full-screen tile.
        // - 1 matched window at depth <= 1 touching 3 screen edges (full width or full height)
        //   covering >= 30% -> single edge-snapped half/pane beside an empty slot.
        let accepted: Bool
        if best.windowCount >= 2 {
            accepted = coverage >= 0.50
        } else if coverage >= 0.85 {
            accepted = true
        } else if best.maxSplitDepth == 1, coverage >= 0.30,
                  let onlyFrame = eligible.first(where: { best.node.windowIDs().contains($0.windowID) })?.frame {
            let fullHeight = abs(onlyFrame.minY - bounds.minY) <= tolerance && abs(onlyFrame.maxY - bounds.maxY) <= tolerance
            let fullWidth = abs(onlyFrame.minX - bounds.minX) <= tolerance && abs(onlyFrame.maxX - bounds.maxX) <= tolerance
            accepted = fullHeight || fullWidth
        } else {
            accepted = false
        }

        guard accepted else { return nil }
        return LayoutTree(root: best.node, nextID: nextID)
    }

    // MARK: - Recursive guillotine partition search

    private struct Solution {
        let node: LayoutTree.Node
        let coveredArea: CGFloat
        let windowCount: Int
        let maxSplitDepth: Int
        let hasEmpty: Bool
    }

    private static func solve(
        region: CGRect,
        candidates: [WindowCandidate],
        depth: Int,
        tolerance: CGFloat,
        allocID: () -> NodeID
    ) -> Solution {
        // 1. Direct 4-edge match (frontmost window wins if two identical maximized windows stack)
        if let match = candidates.first(where: { matchesAllFourEdges($0.frame, region, tolerance: tolerance) }) {
            return Solution(
                node: .window(id: allocID(), windowID: match.windowID),
                coveredArea: region.width * region.height,
                windowCount: 1,
                maxSplitDepth: 0,
                hasEmpty: false
            )
        }

        guard depth < maxDepth, !candidates.isEmpty else {
            return Solution(node: .empty(id: allocID()), coveredArea: 0, windowCount: 0, maxSplitDepth: 0, hasEmpty: true)
        }

        // Collect unique candidate vertical (X) and horizontal (Y) cut coordinates from window edges.
        let vCuts = deduplicatedCuts(
            candidates.flatMap { [$0.frame.minX, $0.frame.maxX] },
            minEdge: region.minX,
            maxEdge: region.maxX,
            tolerance: tolerance
        )
        let hCuts = deduplicatedCuts(
            candidates.flatMap { [$0.frame.minY, $0.frame.maxY] },
            minEdge: region.minY,
            maxEdge: region.maxY,
            tolerance: tolerance
        )

        var best: Solution?

        func evaluateCut(axis: SplitAxis, cutCoord: CGFloat) {
            let ratio = (cutCoord - region.start(along: axis)) / region.span(along: axis)
            guard ratio >= 0.08, ratio <= 0.92 else { return }

            let (firstRect, secondRect, _) = region.splitFlush(axis: axis, ratio: ratio)
            let firstCandidates = candidates.filter { isContained($0.frame, in: firstRect, tolerance: tolerance) }
            let secondCandidates = candidates.filter { isContained($0.frame, in: secondRect, tolerance: tolerance) }

            // At least one side must have a candidate window
            guard !firstCandidates.isEmpty || !secondCandidates.isEmpty else { return }

            let solFirst = solve(
                region: firstRect,
                candidates: firstCandidates,
                depth: depth + 1,
                tolerance: tolerance,
                allocID: allocID
            )
            let solSecond = solve(
                region: secondRect,
                candidates: secondCandidates,
                depth: depth + 1,
                tolerance: tolerance,
                allocID: allocID
            )

            let combinedCount = solFirst.windowCount + solSecond.windowCount
            guard combinedCount > 0 else { return }

            let firstEmpty = solFirst.windowCount == 0
            let secondEmpty = solSecond.windowCount == 0
            // Never wrap a subtree that already contains an empty slot inside another empty-sided
            // cut. Otherwise a floating window sitting inside an empty region gets falsely adopted
            // by carving 2–4 phantom empty strips around it (e.g. empty above and empty below).
            if (firstEmpty && solSecond.hasEmpty) || (secondEmpty && solFirst.hasEmpty) {
                return
            }

            let combinedArea = solFirst.coveredArea + solSecond.coveredArea
            let splitDepth = 1 + max(solFirst.maxSplitDepth, solSecond.maxSplitDepth)
            let combinedHasEmpty = firstEmpty || secondEmpty || solFirst.hasEmpty || solSecond.hasEmpty

            let isBetter: Bool
            if let current = best {
                if abs(combinedArea - current.coveredArea) > 100 {
                    isBetter = combinedArea > current.coveredArea
                } else if combinedCount != current.windowCount {
                    isBetter = combinedCount > current.windowCount
                } else {
                    isBetter = splitDepth < current.maxSplitDepth
                }
            } else {
                isBetter = true
            }

            if isBetter {
                best = Solution(
                    node: .split(
                        id: allocID(),
                        axis: axis,
                        ratio: ratio,
                        first: solFirst.node,
                        second: solSecond.node
                    ),
                    coveredArea: combinedArea,
                    windowCount: combinedCount,
                    maxSplitDepth: splitDepth,
                    hasEmpty: combinedHasEmpty
                )
            }
        }

        for x in vCuts { evaluateCut(axis: .vertical, cutCoord: x) }
        for y in hCuts { evaluateCut(axis: .horizontal, cutCoord: y) }

        return best ?? Solution(node: .empty(id: allocID()), coveredArea: 0, windowCount: 0, maxSplitDepth: 0, hasEmpty: true)
    }

    private static func matchesAllFourEdges(_ frame: CGRect, _ region: CGRect, tolerance: CGFloat) -> Bool {
        abs(frame.minX - region.minX) <= tolerance &&
        abs(frame.maxX - region.maxX) <= tolerance &&
        abs(frame.minY - region.minY) <= tolerance &&
        abs(frame.maxY - region.maxY) <= tolerance
    }

    /// Counts how many of `candidate`'s 4 edges are anchored to either `bounds` (screen edge)
    /// or another adopted window's opposing edge with meaningful overlap.
    private static func anchoredEdgeCount(
        for candidate: WindowCandidate,
        among peers: [WindowCandidate],
        in bounds: CGRect,
        tolerance: CGFloat
    ) -> Int {
        let f = candidate.frame
        let others = peers.filter { $0.windowID != candidate.windowID }

        let leftAnchored = abs(f.minX - bounds.minX) <= tolerance || others.contains { o in
            abs(o.frame.maxX - f.minX) <= tolerance &&
            min(f.maxY, o.frame.maxY) - max(f.minY, o.frame.minY) > tolerance
        }
        let rightAnchored = abs(f.maxX - bounds.maxX) <= tolerance || others.contains { o in
            abs(o.frame.minX - f.maxX) <= tolerance &&
            min(f.maxY, o.frame.maxY) - max(f.minY, o.frame.minY) > tolerance
        }
        let topAnchored = abs(f.minY - bounds.minY) <= tolerance || others.contains { o in
            abs(o.frame.maxY - f.minY) <= tolerance &&
            min(f.maxX, o.frame.maxX) - max(f.minX, o.frame.minX) > tolerance
        }
        let bottomAnchored = abs(f.maxY - bounds.maxY) <= tolerance || others.contains { o in
            abs(o.frame.minY - f.maxY) <= tolerance &&
            min(f.maxX, o.frame.maxX) - max(f.minX, o.frame.minX) > tolerance
        }

        return (leftAnchored ? 1 : 0)
            + (rightAnchored ? 1 : 0)
            + (topAnchored ? 1 : 0)
            + (bottomAnchored ? 1 : 0)
    }

    private static func isContained(_ frame: CGRect, in region: CGRect, tolerance: CGFloat) -> Bool {
        frame.minX >= region.minX - tolerance &&
        frame.maxX <= region.maxX + tolerance &&
        frame.minY >= region.minY - tolerance &&
        frame.maxY <= region.maxY + tolerance
    }

    private static func deduplicatedCuts(
        _ raw: [CGFloat],
        minEdge: CGFloat,
        maxEdge: CGFloat,
        tolerance: CGFloat
    ) -> [CGFloat] {
        let filtered = raw
            .filter { $0 > minEdge + tolerance && $0 < maxEdge - tolerance }
            .sorted()
        var unique: [CGFloat] = []
        for val in filtered {
            if let last = unique.last, abs(val - last) <= 4 {
                continue
            }
            unique.append(val)
        }
        return unique
    }
}
