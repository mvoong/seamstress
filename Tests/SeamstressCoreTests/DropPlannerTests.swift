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
}
