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

    func testIsPointNearEdgeDistinguishesWindowInteriorFromBorder() {
        let win = CGRect(x: 100, y: 200, width: 800, height: 600)

        // Window interior (e.g. Ctrl+Cmd drag-anywhere start) is not near an edge
        XCTAssertFalse(win.isPointNearEdge(CGPoint(x: 500, y: 500)))
        XCTAssertFalse(win.isPointNearEdge(CGPoint(x: 120, y: 220)))

        // Perimeter, corners, and just outside the border (native resize hotzone) are near an edge
        XCTAssertTrue(win.isPointNearEdge(CGPoint(x: 100, y: 500)))
        XCTAssertTrue(win.isPointNearEdge(CGPoint(x: 902, y: 500)))
        XCTAssertTrue(win.isPointNearEdge(CGPoint(x: 105, y: 205)))
        XCTAssertTrue(win.isPointNearEdge(CGPoint(x: 500, y: 798)))

        // Far outside the window is not near an edge
        XCTAssertFalse(win.isPointNearEdge(CGPoint(x: 50, y: 500)))
    }

    func testMagneticDetentsSnapAtHalfAndThirds() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 1)
        tree.splitOccupied(leafID: tree.leafID(for: 1)!, edge: .right, with: 2)
        let seam = SeamGeometry.seams(in: tree, spaceKey: space, bounds: screen)[0]

        // Within 7pt of 50% (500pt)
        let nearHalf = SeamGeometry.dragUpdate(pointer: CGPoint(x: 505, y: 400), seam: seam, tree: tree, minSizes: [:])
        XCTAssertEqual(nearHalf.ratio, 0.5, accuracy: 0.0001)
        XCTAssertEqual(nearHalf.snapKind, .detent(0.5))
        XCTAssertFalse(nearHalf.isClamped)

        // Within 7pt of 1/3 (333.33pt)
        let nearOneThird = SeamGeometry.dragUpdate(pointer: CGPoint(x: 338, y: 400), seam: seam, tree: tree, minSizes: [:])
        XCTAssertEqual(nearOneThird.ratio, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(nearOneThird.snapKind, .detent(1.0 / 3.0))
        XCTAssertFalse(nearOneThird.isClamped)

        // Within 7pt of 2/3 (666.67pt)
        let nearTwoThirds = SeamGeometry.dragUpdate(pointer: CGPoint(x: 661, y: 400), seam: seam, tree: tree, minSizes: [:])
        XCTAssertEqual(nearTwoThirds.ratio, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(nearTwoThirds.snapKind, .detent(2.0 / 3.0))

        // Outside 7pt of any detent
        let free = SeamGeometry.dragUpdate(pointer: CGPoint(x: 510, y: 400), seam: seam, tree: tree, minSizes: [:])
        XCTAssertEqual(free.ratio, 0.51, accuracy: 0.0001)
        XCTAssertEqual(free.snapKind, .none)
    }

    func testColinearSeamAlignmentSnappingAndDisableFlag() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 1)
        tree.splitOccupied(leafID: tree.leafID(for: 1)!, edge: .right, with: 2)
        tree.splitOccupied(leafID: tree.leafID(for: 1)!, edge: .bottom, with: 3)
        tree.splitOccupied(leafID: tree.leafID(for: 2)!, edge: .bottom, with: 4)

        // Move left horizontal seam to y = 320 (ratio 0.4 on 800pt height)
        let initialSeams = SeamGeometry.seams(in: tree, spaceKey: space, bounds: screen)
        let leftH = initialSeams.first { $0.axis == .horizontal && $0.parentBounds.minX == 0 }!
        tree.setRatio(splitID: leftH.splitID, ratio: 0.4)

        let updatedSeams = SeamGeometry.seams(in: tree, spaceKey: space, bounds: screen)
        let rightH = updatedSeams.first { $0.axis == .horizontal && $0.parentBounds.minX == 500 }!

        // Drag right horizontal seam to y = 325 (within 7pt of leftH's seamPosition 320)
        let aligned = SeamGeometry.dragUpdate(
            pointer: CGPoint(x: 750, y: 325),
            seam: rightH,
            tree: tree,
            minSizes: [:],
            allSeams: updatedSeams
        )
        XCTAssertEqual(aligned.seamPosition, 320)
        XCTAssertEqual(aligned.ratio, 0.4, accuracy: 0.0001)
        XCTAssertEqual(aligned.snapKind, .alignedSeam(320))

        // With disableSnapping = true, neither aligned seam nor detents engage
        let disabled = SeamGeometry.dragUpdate(
            pointer: CGPoint(x: 750, y: 325),
            seam: rightH,
            tree: tree,
            minSizes: [:],
            allSeams: updatedSeams,
            disableSnapping: true
        )
        XCTAssertEqual(disabled.ratio, 325.0 / 800.0, accuracy: 0.0001)
        XCTAssertEqual(disabled.snapKind, .none)
    }

    func testGrabOffsetPreventsInitialSeamJump() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 1)
        tree.splitOccupied(leafID: tree.leafID(for: 1)!, edge: .right, with: 2)
        let seam = SeamGeometry.seams(in: tree, spaceKey: space, bounds: screen)[0]

        // User clicked 4pt to the right of the seam at x=504 (grabOffset = +4)
        let atGrab = SeamGeometry.dragUpdate(
            pointer: CGPoint(x: 504, y: 400),
            seam: seam,
            tree: tree,
            minSizes: [:],
            disableSnapping: true,
            grabOffset: 4
        )
        XCTAssertEqual(atGrab.ratio, 0.5, accuracy: 0.0001)
        XCTAssertEqual(atGrab.seamPosition, 500)

        let moved = SeamGeometry.dragUpdate(
            pointer: CGPoint(x: 604, y: 400),
            seam: seam,
            tree: tree,
            minSizes: [:],
            disableSnapping: true,
            grabOffset: 4
        )
        XCTAssertEqual(moved.ratio, 0.6, accuracy: 0.0001)
        XCTAssertEqual(moved.seamPosition, 600)
    }

    func testClampFeedbackFlagsClampedAndClearsUnreachableSnap() {
        var tree = LayoutTree()
        tree.fillEmpty(leafID: tree.root.id, with: 1)
        tree.splitOccupied(leafID: tree.leafID(for: 1)!, edge: .right, with: 2)
        let seam = SeamGeometry.seams(in: tree, spaceKey: space, bounds: screen)[0]

        // Window 1 requires at least 400px (minRatio = 0.4), so 1/3 detent (333px) is unreachable
        let minSizes: [WindowID: CGSize] = [1: CGSize(width: 400, height: 200)]
        let clampedAtDetent = SeamGeometry.dragUpdate(
            pointer: CGPoint(x: 334, y: 400),
            seam: seam,
            tree: tree,
            minSizes: minSizes
        )
        XCTAssertEqual(clampedAtDetent.ratio, 0.4, accuracy: 0.0001)
        XCTAssertTrue(clampedAtDetent.isClamped)
        XCTAssertEqual(clampedAtDetent.snapKind, .none)

        // Within valid range is not clamped
        let unclamped = SeamGeometry.dragUpdate(
            pointer: CGPoint(x: 550, y: 400),
            seam: seam,
            tree: tree,
            minSizes: minSizes
        )
        XCTAssertFalse(unclamped.isClamped)
    }

    func testOverConstrainedEmptySplitAllowsDraggingTowardEmptySideToCollapse() {
        // Window 1 has minWidth 760 inside a 766px container next to an empty right half:
        // computedMin (760/766 = 0.992) > computedMax (1 - 48/766 = 0.937).
        let halfScreen = CGRect(x: 0, y: 0, width: 766, height: 950)
        var tree = LayoutTree()
        tree.splitEmpty(leafID: tree.root.id, edge: .left, with: 1)
        let seam = SeamGeometry.seams(in: tree, spaceKey: space, bounds: halfScreen)[0]
        let minSizes: [WindowID: CGSize] = [1: CGSize(width: 760, height: 512)]

        // Dragging right toward the empty side must move instead of freezing at 0.5
        let dragRight = SeamGeometry.dragUpdate(
            pointer: CGPoint(x: 600, y: 475),
            seam: seam,
            tree: tree,
            minSizes: minSizes,
            disableSnapping: true
        )
        XCTAssertEqual(dragRight.collapseTarget, .none)
        XCTAssertGreaterThan(dragRight.ratio, 0.75)

        // Dragging past 90% triggers collapseSecond
        let dragCollapse = SeamGeometry.dragUpdate(
            pointer: CGPoint(x: 720, y: 475),
            seam: seam,
            tree: tree,
            minSizes: minSizes,
            disableSnapping: true
        )
        XCTAssertEqual(dragCollapse.collapseTarget, .collapseSecond(expandedBounds: halfScreen))
    }
}
