import CoreGraphics
import XCTest
@testable import SeamstressCore

final class DropPlannerTests: XCTestCase {
    private let space = SpaceKey(displayUUID: "MAIN", spaceID: 1)
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testEmptyScreenCenterFills100Percent() {
        let tree = LayoutTree()
        let plan = DropPlanner.plan(
            pointer: CGPoint(x: 500, y: 400),
            draggedWindowID: 10,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(plan?.action, .fillEmpty(leafID: tree.root.id))
        XCTAssertEqual(plan?.previewRect, screen)
        XCTAssertEqual(plan?.previewKind, .fill)
    }

    func testEmptyScreenEdgeSnapsToHalf() {
        let tree = LayoutTree()
        let leftPlan = DropPlanner.plan(
            pointer: CGPoint(x: 40, y: 400),
            draggedWindowID: 10,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(leftPlan?.action, .splitEmpty(leafID: tree.root.id, edge: .left))
        XCTAssertEqual(leftPlan?.previewRect, CGRect(x: 0, y: 0, width: 500, height: 800))

        let bottomPlan = DropPlanner.plan(
            pointer: CGPoint(x: 500, y: 760),
            draggedWindowID: 10,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(bottomPlan?.action, .splitEmpty(leafID: tree.root.id, edge: .bottom))
        XCTAssertEqual(bottomPlan?.previewRect, CGRect(x: 0, y: 400, width: 1000, height: 400))
    }

    func testOccupiedSlotCenterSwapsOuterSplits() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 10)
        let leafID = tree.leafID(for: 10)!

        // Center replaces when dragged window is floating (not in tree)
        let replacePlan = DropPlanner.plan(
            pointer: CGPoint(x: 500, y: 400),
            draggedWindowID: 20,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(replacePlan?.action, .swapOrReplace(leafID: leafID, targetWindowID: 10))
        XCTAssertEqual(replacePlan?.previewKind, .replace)
        XCTAssertEqual(replacePlan?.previewRect, screen)

        // Center swaps when dragged window is tiled (e.g. from another monitor)
        let swapPlan = DropPlanner.plan(
            pointer: CGPoint(x: 500, y: 400),
            draggedWindowID: 20,
            targetSpace: space,
            tree: tree,
            screenBounds: screen,
            isDraggedWindowTiled: true
        )
        XCTAssertEqual(swapPlan?.action, .swapOrReplace(leafID: leafID, targetWindowID: 10))
        XCTAssertEqual(swapPlan?.previewKind, .swap)
        XCTAssertEqual(swapPlan?.previewRect, screen)

        // Right outer splits vertically on right
        let splitPlan = DropPlanner.plan(
            pointer: CGPoint(x: 880, y: 400),
            draggedWindowID: 20,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(splitPlan?.action, .splitOccupied(leafID: leafID, edge: .right))
        XCTAssertEqual(splitPlan?.previewKind, .split)
        XCTAssertEqual(splitPlan?.previewRect, CGRect(x: 500, y: 0, width: 500, height: 800))
    }

    func testDraggingOwnSlotToEdgeShrinksToHalf() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 10)
        let leafID = tree.leafID(for: 10)!

        let edgePlan = DropPlanner.plan(
            pointer: CGPoint(x: 30, y: 400),
            draggedWindowID: 10,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(edgePlan?.action, .shrinkOwnSlot(leafID: leafID, edge: .left))
        XCTAssertEqual(edgePlan?.previewRect, CGRect(x: 0, y: 0, width: 500, height: 800))

        let centerPlan = DropPlanner.plan(
            pointer: CGPoint(x: 500, y: 400),
            draggedWindowID: 10,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(centerPlan?.action, .keepInPlace(leafID: leafID))
    }

    func testTJunctionOnVerticalSplitSplitsEntireContainerHorizontally() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 10)
        tree.splitOccupied(leafID: tree.leafID(for: 10)!, edge: .right, with: 20)
        let rootSplitID = tree.root.id

        // Dragging near top-center "T" (500, 15) spans full width across both panes
        let topT = DropPlanner.plan(
            pointer: CGPoint(x: 500, y: 15),
            draggedWindowID: 30,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(topT?.action, .splitNode(nodeID: rootSplitID, edge: .top))
        XCTAssertEqual(topT?.previewKind, .splitContainer)
        XCTAssertEqual(topT?.previewRect, CGRect(x: 0, y: 0, width: 1000, height: 400))

        // Dragging near bottom-center "T" (500, 785) spans full width on bottom half
        let bottomT = DropPlanner.plan(
            pointer: CGPoint(x: 500, y: 785),
            draggedWindowID: 30,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(bottomT?.action, .splitNode(nodeID: rootSplitID, edge: .bottom))
        XCTAssertEqual(bottomT?.previewKind, .splitContainer)
        XCTAssertEqual(bottomT?.previewRect, CGRect(x: 0, y: 400, width: 1000, height: 400))

        // Dragging near top-left (150, 15) away from the T still splits only window 10
        let leftOnly = DropPlanner.plan(
            pointer: CGPoint(x: 150, y: 15),
            draggedWindowID: 30,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(leftOnly?.action, .splitOccupied(leafID: tree.leafID(for: 10)!, edge: .top))
        XCTAssertEqual(leftOnly?.previewRect, CGRect(x: 0, y: 0, width: 500, height: 400))
    }

    func testTJunctionOnHorizontalSplitSplitsEntireContainerVertically() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 10)
        tree.splitOccupied(leafID: tree.leafID(for: 10)!, edge: .bottom, with: 20)
        let rootSplitID = tree.root.id

        // Dragging near left-middle "T" (20, 400) spans full height on left half
        let leftT = DropPlanner.plan(
            pointer: CGPoint(x: 20, y: 400),
            draggedWindowID: 30,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(leftT?.action, .splitNode(nodeID: rootSplitID, edge: .left))
        XCTAssertEqual(leftT?.previewKind, .splitContainer)
        XCTAssertEqual(leftT?.previewRect, CGRect(x: 0, y: 0, width: 500, height: 800))

        // Dragging near right-middle "T" (980, 400) spans full height on right half
        let rightT = DropPlanner.plan(
            pointer: CGPoint(x: 980, y: 400),
            draggedWindowID: 30,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(rightT?.action, .splitNode(nodeID: rootSplitID, edge: .right))
        XCTAssertEqual(rightT?.previewKind, .splitContainer)
        XCTAssertEqual(rightT?.previewRect, CGRect(x: 500, y: 0, width: 500, height: 800))
    }

    func testSameSpaceResplitProducesWYSIWYGPreviewRect() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 10)
        tree.splitOccupied(leafID: tree.leafID(for: 10)!, edge: .right, with: 20)
        let leafB = tree.leafID(for: 20)!

        // Dragging left pane 10 onto top edge of right pane 20 collapses 10's old slot,
        // so 10 lands in the full-width top half rather than just the top-right quarter.
        let plan = DropPlanner.plan(
            pointer: CGPoint(x: 750, y: 30),
            draggedWindowID: 10,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(plan?.action, .splitOccupied(leafID: leafB, edge: .top))
        XCTAssertEqual(plan?.previewKind, .split)
        XCTAssertEqual(plan?.previewRect, CGRect(x: 0, y: 0, width: 1000, height: 400))

        // Same-space swap on center of right pane 20 defaults to .swap because 10 is in tree
        let swapPlan = DropPlanner.plan(
            pointer: CGPoint(x: 750, y: 400),
            draggedWindowID: 10,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(swapPlan?.action, .swapOrReplace(leafID: leafB, targetWindowID: 20))
        XCTAssertEqual(swapPlan?.previewKind, .swap)
        XCTAssertEqual(swapPlan?.previewRect, CGRect(x: 500, y: 0, width: 500, height: 800))
    }

    func testSameSpaceTJunctionResplitProducesWYSIWYGPreviewRect() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 10)
        tree.splitOccupied(leafID: tree.leafID(for: 10)!, edge: .right, with: 20)
        tree.splitOccupied(leafID: tree.leafID(for: 20)!, edge: .bottom, with: 30)

        // Dragging left pane 10 onto the left T-junction of [20 / 30] (x=520, y=400)
        // collapses 10's old slot so the right subtree expands to full screen before splitting left.
        let plan = DropPlanner.plan(
            pointer: CGPoint(x: 520, y: 400),
            draggedWindowID: 10,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
        )
        XCTAssertEqual(plan?.previewKind, .splitContainer)
        XCTAssertEqual(plan?.previewRect, CGRect(x: 0, y: 0, width: 500, height: 800))
    }

    func testMinSizePreventsImpossibleQuarterShrinkAndClampsHalfSplitRatio() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 950)
        // Window 10 has min width 760 (larger than half of 1512 = 756, and far larger than a 378px quarter)
        let minSizes: [WindowID: CGSize] = [10: CGSize(width: 760, height: 512), 20: CGSize(width: 336, height: 208)]

        // 1. Snapping window 10 to left edge of full 1512px empty screen succeeds with clamped ratio >= 760/1512
        let emptyTree = LayoutTree()
        let leftHalf = DropPlanner.plan(
            pointer: CGPoint(x: 30, y: 475),
            draggedWindowID: 10,
            targetSpace: space,
            tree: emptyTree,
            screenBounds: laptop,
            minSizes: minSizes
        )
        XCTAssertEqual(leftHalf?.action, .splitEmpty(leafID: emptyTree.root.id, edge: .left))
        XCTAssertGreaterThanOrEqual(leftHalf?.previewRect.width ?? 0, 760)
        XCTAssertGreaterThan(leftHalf?.splitRatio ?? 0, 0.5)

        // 2. Once window 10 occupies the 766px left half next to window 20, dragging 10 to its own left edge
        //    cannot shrink it into a quarter (760 + 140 > 766) -> falls back to keepInPlace.
        var splitTree = LayoutTree()
        splitTree.fillEmpty(leafID: splitTree.root.id, with: 10)
        splitTree.splitOccupied(leafID: splitTree.leafID(for: 10)!, edge: .right, ratio: 766.0 / 1512.0, with: 20)
        let leaf10 = splitTree.leafID(for: 10)!

        let shrinkAttempt = DropPlanner.plan(
            pointer: CGPoint(x: 20, y: 475),
            draggedWindowID: 10,
            targetSpace: space,
            tree: splitTree,
            screenBounds: laptop,
            minSizes: minSizes
        )
        XCTAssertEqual(shrinkAttempt?.action, .keepInPlace(leafID: leaf10))
        XCTAssertEqual(shrinkAttempt?.previewKind, .fill)

        // 3. Dragging a third window (min width 300) onto the left edge of 10's 766px slot cannot split
        //    horizontally (760 + 300 > 766) -> falls back to replace instead of creating an overflowing split.
        let minSizesWith30 = minSizes.merging([30: CGSize(width: 300, height: 200)]) { _, new in new }
        let horizontalSplitAttempt = DropPlanner.plan(
            pointer: CGPoint(x: 20, y: 475),
            draggedWindowID: 30,
            targetSpace: space,
            tree: splitTree,
            screenBounds: laptop,
            minSizes: minSizesWith30
        )
        XCTAssertEqual(horizontalSplitAttempt?.action, .swapOrReplace(leafID: leaf10, targetWindowID: 10))
        XCTAssertEqual(horizontalSplitAttempt?.previewKind, .replace)

        // 4. Vertical (top/bottom) split of 10's 766x950 slot still fits (512 + 200 <= 950) with clamped ratio.
        let verticalSplitAttempt = DropPlanner.plan(
            pointer: CGPoint(x: 380, y: 30),
            draggedWindowID: 30,
            targetSpace: space,
            tree: splitTree,
            screenBounds: laptop,
            minSizes: minSizesWith30
        )
        XCTAssertEqual(verticalSplitAttempt?.action, .splitOccupied(leafID: leaf10, edge: .top))
        XCTAssertEqual(verticalSplitAttempt?.previewKind, .split)
        XCTAssertLessThanOrEqual(verticalSplitAttempt?.previewRect.height ?? 999, 950 - 512 + 1)
    }

    func testNestedTJunctionIgnoresMinSizeOfWindowsOutsideContainer() {
        // Layout: [10 (left 500x800) | (20 top-right 500x400 / 30 bottom-right 500x400)]
        // Window 10 (outside the nested right split) has a huge minWidth (600px).
        // Dragging window 20 onto the right T-junction of its own nested [20 / 30] container
        // collapses [20 / 30] to just [30] inside the 500px right column; splitting [30]
        // vertically with 20 (minWidth 200 each -> 400 <= 500) must succeed without counting 10.
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 10)
        tree.splitOccupied(leafID: tree.leafID(for: 10)!, edge: .right, with: 20)
        tree.splitOccupied(leafID: tree.leafID(for: 20)!, edge: .bottom, with: 30)

        let minSizes: [WindowID: CGSize] = [
            10: CGSize(width: 600, height: 200),
            20: CGSize(width: 200, height: 200),
            30: CGSize(width: 200, height: 200),
        ]

        let plan = DropPlanner.plan(
            pointer: CGPoint(x: 980, y: 400),
            draggedWindowID: 20,
            targetSpace: space,
            tree: tree,
            screenBounds: screen,
            minSizes: minSizes
        )
        XCTAssertEqual(plan?.previewKind, .splitContainer)
        XCTAssertEqual(plan?.previewRect, CGRect(x: 750, y: 0, width: 250, height: 800))
    }

    func testInfeasibleVerticalAxisAllocatesFullWidthTopAndBottomZones() {
        // Mirrors a narrow ultrawide column (806x1440, min 720x532) targeted by a floating
        // window (min 420x320): left/right cannot fit (720 + 420 > 806), while top/bottom
        // fits comfortably (532 + 320 <= 1440).
        let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 10)
        tree.splitOccupied(leafID: tree.leafID(for: 10)!, edge: .right, ratio: 2634.0 / 3440.0, with: 20)
        let leaf20 = tree.leafID(for: 20)!

        let minSizes: [WindowID: CGSize] = [
            20: CGSize(width: 720, height: 532),
            30: CGSize(width: 420, height: 320),
        ]

        // Bottom-left, bottom-center, and bottom-right of window 20 all split .bottom
        // instead of falling into an infeasible .left/.right -> .replace zone.
        for x in [CGFloat(2660), CGFloat(3037), CGFloat(3410)] {
            let bottomPlan = DropPlanner.plan(
                pointer: CGPoint(x: x, y: 1050),
                draggedWindowID: 30,
                targetSpace: space,
                tree: tree,
                screenBounds: ultrawide,
                minSizes: minSizes
            )
            XCTAssertEqual(bottomPlan?.action, .splitOccupied(leafID: leaf20, edge: .bottom), "Failed at x=\(x)")
            XCTAssertEqual(bottomPlan?.previewKind, .split)
            XCTAssertEqual(bottomPlan?.previewRect, CGRect(x: 2634, y: 720, width: 806, height: 720))
        }

        // Top-left and top-right also split .top across the full column width.
        for x in [CGFloat(2660), CGFloat(3410)] {
            let topPlan = DropPlanner.plan(
                pointer: CGPoint(x: x, y: 300),
                draggedWindowID: 30,
                targetSpace: space,
                tree: tree,
                screenBounds: ultrawide,
                minSizes: minSizes
            )
            XCTAssertEqual(topPlan?.action, .splitOccupied(leafID: leaf20, edge: .top), "Failed at x=\(x)")
            XCTAssertEqual(topPlan?.previewKind, .split)
            XCTAssertEqual(topPlan?.previewRect, CGRect(x: 2634, y: 0, width: 806, height: 720))
        }

        // Middle vertical band (including its left/right edges) still replaces cleanly.
        for x in [CGFloat(2660), CGFloat(3037), CGFloat(3410)] {
            let midPlan = DropPlanner.plan(
                pointer: CGPoint(x: x, y: 720),
                draggedWindowID: 30,
                targetSpace: space,
                tree: tree,
                screenBounds: ultrawide,
                minSizes: minSizes
            )
            XCTAssertEqual(midPlan?.action, .swapOrReplace(leafID: leaf20, targetWindowID: 20), "Failed at x=\(x)")
            XCTAssertEqual(midPlan?.previewKind, .replace)
        }
    }

    func testInfeasibleHorizontalAxisAllocatesFullHeightLeftAndRightZones() {
        // Short wide slot (1000x400) where top/bottom cannot fit (300 + 250 > 400)
        // but left/right fits (300 + 300 <= 1000).
        let shortScreen = CGRect(x: 0, y: 0, width: 1000, height: 400)
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 10)
        let leaf10 = tree.leafID(for: 10)!
        let minSizes: [WindowID: CGSize] = [
            10: CGSize(width: 300, height: 300),
            20: CGSize(width: 300, height: 250),
        ]

        // Bottom-left corner picks .left instead of infeasible .bottom -> .replace.
        let leftPlan = DropPlanner.plan(
            pointer: CGPoint(x: 150, y: 380),
            draggedWindowID: 20,
            targetSpace: space,
            tree: tree,
            screenBounds: shortScreen,
            minSizes: minSizes
        )
        XCTAssertEqual(leftPlan?.action, .splitOccupied(leafID: leaf10, edge: .left))
        XCTAssertEqual(leftPlan?.previewKind, .split)

        // Top-center (inside horizontal middle band) falls back to .replace.
        let midTop = DropPlanner.plan(
            pointer: CGPoint(x: 500, y: 20),
            draggedWindowID: 20,
            targetSpace: space,
            tree: tree,
            screenBounds: shortScreen,
            minSizes: minSizes
        )
        XCTAssertEqual(midTop?.action, .swapOrReplace(leafID: leaf10, targetWindowID: 10))
        XCTAssertEqual(midTop?.previewKind, .replace)
    }

    func testOwnSlotAndEmptySlotCornerFallBackToFeasibleEdge() {
        // Narrow 806x1440 column for window 20 (min 720x532): shrinking left/right is impossible
        // (720 + 140 > 806), so dragging to its own bottom-left corner picks .bottom instead of keepInPlace.
        let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 10)
        tree.splitOccupied(leafID: tree.leafID(for: 10)!, edge: .right, ratio: 2634.0 / 3440.0, with: 20)
        let leaf20 = tree.leafID(for: 20)!
        let minSizes: [WindowID: CGSize] = [20: CGSize(width: 720, height: 532)]

        // Pointer is closer to right edge (dRight=10 / 145 = 0.069) than bottom edge (dBottom=40 / 220 = 0.18),
        // away from the vertical seam T-junction, and .right is infeasible so .bottom wins.
        let ownShrink = DropPlanner.plan(
            pointer: CGPoint(x: 3430, y: 1400),
            draggedWindowID: 20,
            targetSpace: space,
            tree: tree,
            screenBounds: ultrawide,
            minSizes: minSizes
        )
        XCTAssertEqual(ownShrink?.action, .shrinkOwnSlot(leafID: leaf20, edge: .bottom))
        XCTAssertEqual(ownShrink?.previewKind, .split)

        // Same corner behavior for an empty narrow slot when dragging window 20 into it.
        tree.removeWindow(20)
        let emptyLeafID = tree.leaf(at: CGPoint(x: 3430, y: 1400), in: ultrawide)!.leafID
        let emptySplit = DropPlanner.plan(
            pointer: CGPoint(x: 3430, y: 1400),
            draggedWindowID: 20,
            targetSpace: space,
            tree: tree,
            screenBounds: ultrawide,
            minSizes: minSizes
        )
        XCTAssertEqual(emptySplit?.action, .splitEmpty(leafID: emptyLeafID, edge: .bottom))
        XCTAssertEqual(emptySplit?.previewKind, .split)
    }
}
