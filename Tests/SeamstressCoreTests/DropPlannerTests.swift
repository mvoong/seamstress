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

        // Center swaps
        let swapPlan = DropPlanner.plan(
            pointer: CGPoint(x: 500, y: 400),
            draggedWindowID: 20,
            targetSpace: space,
            tree: tree,
            screenBounds: screen
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
        XCTAssertEqual(rightT?.previewRect, CGRect(x: 500, y: 0, width: 500, height: 800))
    }
}
