import CoreGraphics
import XCTest
@testable import SeamstressCore

final class LayoutTreeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 25, width: 1600, height: 975)

    func testEmptyTreeFillsFullScreen() {
        var tree = LayoutTree()
        XCTAssertTrue(tree.isEmpty)
        let rootLeaf = tree.leaf(at: CGPoint(x: 800, y: 500), in: screen)!
        XCTAssertTrue(rootLeaf.isEmpty)
        XCTAssertEqual(rootLeaf.frame, screen)

        XCTAssertTrue(tree.fillEmpty(leafID: rootLeaf.leafID, with: 101))
        XCTAssertFalse(tree.isEmpty)
        XCTAssertEqual(tree.windowFrames(in: screen), [101: screen])
    }

    func testSplitEmptyLeavesOppositeHalfEmpty() {
        var tree = LayoutTree()
        let rootID = tree.root.id
        XCTAssertTrue(tree.splitEmpty(leafID: rootID, edge: .left, with: 101))

        let leaves = tree.leafPlacements(in: screen)
        XCTAssertEqual(leaves.count, 2)
        XCTAssertEqual(leaves[0].windowID, 101)
        XCTAssertEqual(leaves[0].frame, CGRect(x: 0, y: 25, width: 800, height: 975))
        XCTAssertNil(leaves[1].windowID)
        XCTAssertEqual(leaves[1].frame, CGRect(x: 800, y: 25, width: 800, height: 975))

        // Filling the empty right half
        XCTAssertTrue(tree.fillEmpty(leafID: leaves[1].leafID, with: 102))
        XCTAssertEqual(tree.windowFrames(in: screen)[102], CGRect(x: 800, y: 25, width: 800, height: 975))
    }

    func testRemoveWindowKeepsEmptySlotUntilBothSidesEmpty() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 101)
        let leafA = tree.leafID(for: 101)!
        tree.splitOccupied(leafID: leafA, edge: .right, with: 102)

        // Removing 102 keeps right half empty; 101 stays on left half
        XCTAssertTrue(tree.removeWindow(102))
        let framesAfterFirstRemove = tree.windowFrames(in: screen)
        XCTAssertEqual(framesAfterFirstRemove[101], CGRect(x: 0, y: 25, width: 800, height: 975))
        XCTAssertEqual(tree.leafPlacements(in: screen).count, 2)
        XCTAssertTrue(tree.leafPlacements(in: screen)[1].isEmpty)

        // Removing 101 collapses double-empty split back to single empty root
        XCTAssertTrue(tree.removeWindow(101))
        XCTAssertTrue(tree.isEmpty)
        XCTAssertEqual(tree.leafPlacements(in: screen).count, 1)
        XCTAssertEqual(tree.leafPlacements(in: screen)[0].frame, screen)
    }

    func testCollapseEmptyChildAndDoubleClickReset() {
        var tree = LayoutTree()
        tree.splitEmpty(leafID: tree.root.id, edge: .left, with: 101)
        let splitID = tree.root.id

        // Double-click collapses empty right child -> 101 expands to 100%
        XCTAssertTrue(tree.handleSeamDoubleClick(splitID: splitID))
        XCTAssertEqual(tree.windowFrames(in: screen), [101: screen])

        // Split with 102, resize to 0.7, double-click resets to 0.5
        tree.splitOccupied(leafID: tree.leafID(for: 101)!, edge: .right, with: 102)
        let splitID2 = tree.root.id
        tree.setRatio(splitID: splitID2, ratio: 0.7)
        XCTAssertEqual(tree.windowFrames(in: screen)[101]?.width, 1120)

        XCTAssertTrue(tree.handleSeamDoubleClick(splitID: splitID2))
        XCTAssertEqual(tree.windowFrames(in: screen)[101]?.width, 800)
        XCTAssertEqual(tree.windowFrames(in: screen)[102]?.width, 800)
    }

    func testFlushSplitHasNoOverlapOrGapOnOddDimensions() {
        let odd = CGRect(x: 0, y: 0, width: 1513, height: 983)
        let (left, right, seamX) = odd.splitFlush(axis: .vertical, ratio: 0.5)
        XCTAssertEqual(left.maxX, seamX)
        XCTAssertEqual(right.minX, seamX)
        XCTAssertEqual(left.width + right.width, odd.width)
        XCTAssertEqual(left.maxX, right.minX)
    }
}
