import CoreGraphics
import XCTest
@testable import SeamstressCore

final class SeamGeometryTests: XCTestCase {
    private let space = SpaceKey(displayUUID: "MAIN", spaceID: 1)
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testSeamHitTestAndLiveResizeClamping() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 1)
        tree.splitOccupied(leafID: tree.leafID(for: 1)!, edge: .right, with: 2)

        let seams = SeamGeometry.seams(in: tree, spaceKey: space, bounds: screen)
        XCTAssertEqual(seams.count, 1)
        XCTAssertEqual(seams[0].seamPosition, 500)
        XCTAssertEqual(seams[0].hitRect, CGRect(x: 495, y: 0, width: 10, height: 800))

        // Inside 10px hit strip
        XCTAssertEqual(SeamGeometry.hitTest(point: CGPoint(x: 504, y: 300), seams: seams)?.splitID, seams[0].splitID)
        // Outside hit strip
        XCTAssertNil(SeamGeometry.hitTest(point: CGPoint(x: 506, y: 300), seams: seams))

        // Clamps against learned min size of window 1 (300px) and window 2 (400px)
        let minSizes: [WindowID: CGSize] = [1: CGSize(width: 300, height: 200), 2: CGSize(width: 400, height: 200)]
        let tooLeft = SeamGeometry.dragUpdate(pointer: CGPoint(x: 100, y: 400), seam: seams[0], tree: tree, minSizes: minSizes)
        XCTAssertEqual(tooLeft.ratio, 0.3, accuracy: 0.001)
        XCTAssertEqual(tooLeft.collapseTarget, .none)

        let tooRight = SeamGeometry.dragUpdate(pointer: CGPoint(x: 900, y: 400), seam: seams[0], tree: tree, minSizes: minSizes)
        XCTAssertEqual(tooRight.ratio, 0.6, accuracy: 0.001)
        XCTAssertEqual(tooRight.collapseTarget, .none)
    }

    func testDragPast90PercentIntoEmptySlotTriggersCollapse() {
        var tree = LayoutTree()
        tree.splitEmpty(leafID: tree.root.id, edge: .left, with: 1)
        let seams = SeamGeometry.seams(in: tree, spaceKey: space, bounds: screen)
        XCTAssertEqual(seams.count, 1)
        XCTAssertTrue(seams[0].secondIsEmpty)

        // At 85% -> normal resize, no collapse
        let resize = SeamGeometry.dragUpdate(pointer: CGPoint(x: 850, y: 400), seam: seams[0], tree: tree, minSizes: [:])
        XCTAssertEqual(resize.collapseTarget, .none)
        XCTAssertEqual(resize.ratio, 0.85, accuracy: 0.001)

        // At 92% -> triggers collapseSecond
        let collapse = SeamGeometry.dragUpdate(pointer: CGPoint(x: 920, y: 400), seam: seams[0], tree: tree, minSizes: [:])
        XCTAssertEqual(collapse.collapseTarget, .collapseSecond(expandedBounds: screen))
    }

    func testHitTestTargetDetectsIntersectionInFourPaneGrid() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 1)
        tree.splitOccupied(leafID: tree.leafID(for: 1)!, edge: .right, with: 2)
        tree.splitOccupied(leafID: tree.leafID(for: 1)!, edge: .bottom, with: 3)
        tree.splitOccupied(leafID: tree.leafID(for: 2)!, edge: .bottom, with: 4)

        let seams = SeamGeometry.seams(in: tree, spaceKey: space, bounds: screen)
        // Center intersection (500, 400) hits the vertical seam AND BOTH horizontal seams (left & right)
        let hit = SeamGeometry.hitTestTarget(point: CGPoint(x: 500, y: 400), seams: seams)
        if case .intersection(let vs, let hs) = hit {
            XCTAssertEqual(vs.count, 1)
            XCTAssertEqual(hs.count, 2)
            XCTAssertTrue(vs.allSatisfy { $0.axis == .vertical })
            XCTAssertTrue(hs.allSatisfy { $0.axis == .horizontal })
        } else {
            XCTFail("Expected 2-axis intersection hit at (500, 400), got \(String(describing: hit))")
        }

        // Away from intersection hits only a single vertical seam
        let verticalOnly = SeamGeometry.hitTestTarget(point: CGPoint(x: 500, y: 150), seams: seams)
        if case .single(let s) = verticalOnly {
            XCTAssertEqual(s.axis, .vertical)
        } else {
            XCTFail("Expected single vertical seam at (500, 150), got \(String(describing: verticalOnly))")
        }
    }
}
