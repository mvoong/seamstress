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
        let eligible = windows.filter { w in
            w.frame.width >= 100 &&
            w.frame.height >= 100 &&
            w.frame.minX >= bounds.minX - tolerance &&
            w.frame.maxX <= bounds.maxX + tolerance &&
            w.frame.minY >= bounds.minY - tolerance &&
            w.frame.maxY <= bounds.maxY + tolerance
        }
        guard !eligible.isEmpty else { return nil }

        var nextID: NodeID = 1
        func allocID() -> NodeID {
            defer { nextID += 1 }
            return nextID
        }

        let best = solve(
            region: bounds,
            candidates: eligible,
            depth: 0,
            tolerance: tolerance,
            allocID: allocID
        )

        guard best.windowCount > 0 else { return nil }

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
                maxSplitDepth: 0
            )
        }

        guard depth < maxDepth, !candidates.isEmpty else {
            return Solution(node: .empty(id: allocID()), coveredArea: 0, windowCount: 0, maxSplitDepth: 0)
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
            let ratio: CGFloat
            switch axis {
            case .vertical:
                ratio = (cutCoord - region.minX) / region.width
            case .horizontal:
                ratio = (cutCoord - region.minY) / region.height
            }
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

            let combinedArea = solFirst.coveredArea + solSecond.coveredArea
            let splitDepth = 1 + max(solFirst.maxSplitDepth, solSecond.maxSplitDepth)

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
                    maxSplitDepth: splitDepth
                )
            }
        }

        for x in vCuts { evaluateCut(axis: .vertical, cutCoord: x) }
        for y in hCuts { evaluateCut(axis: .horizontal, cutCoord: y) }

        return best ?? Solution(node: .empty(id: allocID()), coveredArea: 0, windowCount: 0, maxSplitDepth: 0)
    }

    private static func matchesAllFourEdges(_ frame: CGRect, _ region: CGRect, tolerance: CGFloat) -> Bool {
        abs(frame.minX - region.minX) <= tolerance &&
        abs(frame.maxX - region.maxX) <= tolerance &&
        abs(frame.minY - region.minY) <= tolerance &&
        abs(frame.maxY - region.maxY) <= tolerance
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
