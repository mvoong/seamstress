import CoreGraphics
import XCTest
@testable import SeamstressCore

final class LayoutReconstructorTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 25, width: 1600, height: 975)

    func testReconstructsFullScreenWindow() {
        let windows = [
            WindowCandidate(windowID: 1, frame: CGRect(x: 0, y: 25, width: 1600, height: 975)),
        ]
        let tree = LayoutReconstructor.reconstruct(windows: windows, in: screen)
        XCTAssertNotNil(tree)
        XCTAssertEqual(tree?.allWindowIDs, [1])
        XCTAssertEqual(tree?.windowFrames(in: screen), [1: screen])
    }

    func testReconstructsVerticalSplitWithCustomRatioAndTolerance() {
        // 65/35 vertical split with slight 4pt rounding imperfections
        let windows = [
            WindowCandidate(windowID: 1, frame: CGRect(x: 0, y: 25, width: 1038, height: 973)),
            WindowCandidate(windowID: 2, frame: CGRect(x: 1040, y: 25, width: 560, height: 975)),
        ]
        let tree = LayoutReconstructor.reconstruct(windows: windows, in: screen)
        XCTAssertNotNil(tree)
        XCTAssertEqual(Set(tree?.allWindowIDs ?? []), [1, 2])

        let frames = tree!.windowFrames(in: screen)
        XCTAssertEqual(frames[1]!.width, 1040, accuracy: 6)
        XCTAssertEqual(frames[2]!.width, 560, accuracy: 6)
        XCTAssertEqual(frames[1]!.maxX, frames[2]!.minX)
    }

    func testReconstructsThreePaneNestedLayoutAndIgnoresFloatingWindowOnTop() {
        let windows = [
            // Floating window sitting right over the middle of the screen (frontmost)
            WindowCandidate(windowID: 99, frame: CGRect(x: 500, y: 250, width: 600, height: 420)),
            // 3 tiled windows underneath
            WindowCandidate(windowID: 1, frame: CGRect(x: 0, y: 25, width: 800, height: 975)),
            WindowCandidate(windowID: 2, frame: CGRect(x: 800, y: 25, width: 800, height: 488)),
            WindowCandidate(windowID: 3, frame: CGRect(x: 800, y: 513, width: 800, height: 487)),
        ]
        let tree = LayoutReconstructor.reconstruct(windows: windows, in: screen)
        XCTAssertNotNil(tree)
        XCTAssertEqual(Set(tree?.allWindowIDs ?? []), [1, 2, 3])
        XCTAssertFalse(tree!.contains(windowID: 99))

        let frames = tree!.windowFrames(in: screen)
        XCTAssertEqual(frames[1], CGRect(x: 0, y: 25, width: 800, height: 975))
        XCTAssertEqual(frames[2], CGRect(x: 800, y: 25, width: 800, height: 488))
        XCTAssertEqual(frames[3], CGRect(x: 800, y: 513, width: 800, height: 487))
    }

    func testReconstructsSingleHalfScreenWindowWithEmptySibling() {
        let windows = [
            WindowCandidate(windowID: 1, frame: CGRect(x: 0, y: 25, width: 800, height: 975)),
        ]
        let tree = LayoutReconstructor.reconstruct(windows: windows, in: screen)
        XCTAssertNotNil(tree)
        XCTAssertEqual(tree?.allWindowIDs, [1])
        let leaves = tree!.leafPlacements(in: screen)
        XCTAssertEqual(leaves.count, 2)
        XCTAssertEqual(leaves[0].windowID, 1)
        XCTAssertTrue(leaves[1].isEmpty)
    }

    func testRejectsOrdinaryFloatingWindows() {
        // Centered floating window
        let centered = [
            WindowCandidate(windowID: 1, frame: CGRect(x: 300, y: 150, width: 900, height: 650)),
        ]
        XCTAssertNil(LayoutReconstructor.reconstruct(windows: centered, in: screen))

        // Corner floating window (only touches 2 edges)
        let corner = [
            WindowCandidate(windowID: 2, frame: CGRect(x: 0, y: 25, width: 700, height: 500)),
        ]
        XCTAssertNil(LayoutReconstructor.reconstruct(windows: corner, in: screen))
    }

    func testReconstructsFourHorizontalColumnsWithFloatingWindowsOnTop() {
        let ultrawide = CGRect(x: 0, y: 30, width: 3440, height: 1344)
        let windows = [
            WindowCandidate(windowID: 100, frame: CGRect(x: 914, y: 900, width: 597, height: 385)),
            WindowCandidate(windowID: 1, frame: CGRect(x: 0, y: 30, width: 1385, height: 1344)),
            WindowCandidate(windowID: 101, frame: CGRect(x: 1568, y: 551, width: 1641, height: 672)),
            WindowCandidate(windowID: 102, frame: CGRect(x: 572, y: 275, width: 756, height: 949)),
            WindowCandidate(windowID: 4, frame: CGRect(x: 2709, y: 30, width: 731, height: 1343)),
            WindowCandidate(windowID: 3, frame: CGRect(x: 1978, y: 30, width: 731, height: 1343)),
            WindowCandidate(windowID: 2, frame: CGRect(x: 1385, y: 30, width: 593, height: 1343)),
        ]
        let tree = LayoutReconstructor.reconstruct(windows: windows, in: ultrawide)
        XCTAssertNotNil(tree)
        XCTAssertEqual(Set(tree?.allWindowIDs ?? []), [1, 2, 3, 4])
    }

    func testIgnoresFloatingWindowSandwichedVerticallyInEmptyColumn() {
        let ultrawide = CGRect(x: 0, y: 30, width: 3440, height: 1410)
        let windows = [
            // Floating window matching column width but with empty gaps above and below
            WindowCandidate(windowID: 10, frame: CGRect(x: 0, y: 182, width: 860, height: 1087)),
            // Two genuinely tiled windows covering the remaining 75%
            WindowCandidate(windowID: 2, frame: CGRect(x: 860, y: 30, width: 860, height: 1410)),
            WindowCandidate(windowID: 3, frame: CGRect(x: 1720, y: 30, width: 1720, height: 1410)),
        ]
        let tree = LayoutReconstructor.reconstruct(windows: windows, in: ultrawide)
        XCTAssertNotNil(tree)
        XCTAssertEqual(Set(tree?.allWindowIDs ?? []), [2, 3])
        XCTAssertFalse(tree!.contains(windowID: 10))

        let emptyLeaves = tree!.leafPlacements(in: ultrawide).filter(\.isEmpty)
        XCTAssertEqual(emptyLeaves.count, 1)
        XCTAssertEqual(emptyLeaves[0].frame, CGRect(x: 0, y: 30, width: 860, height: 1410))
    }

    func testIgnoresFloatingWindowCenteredOrCorneredInsideEmptyColumn() {
        let ultrawide = CGRect(x: 0, y: 30, width: 3440, height: 1410)
        let tiled = [
            WindowCandidate(windowID: 2, frame: CGRect(x: 860, y: 30, width: 860, height: 1410)),
            WindowCandidate(windowID: 3, frame: CGRect(x: 1720, y: 30, width: 1720, height: 1410)),
        ]

        // Floating window centered inside the empty left column (gaps on all 4 sides)
        let centeredTree = LayoutReconstructor.reconstruct(
            windows: [WindowCandidate(windowID: 10, frame: CGRect(x: 100, y: 200, width: 660, height: 900))] + tiled,
            in: ultrawide
        )
        XCTAssertNotNil(centeredTree)
        XCTAssertEqual(Set(centeredTree?.allWindowIDs ?? []), [2, 3])

        // Floating window tucked into the top-left corner of the empty left column (gaps on 2 adjacent sides)
        let cornerTree = LayoutReconstructor.reconstruct(
            windows: [WindowCandidate(windowID: 11, frame: CGRect(x: 0, y: 30, width: 620, height: 820))] + tiled,
            in: ultrawide
        )
        XCTAssertNotNil(cornerTree)
        XCTAssertEqual(Set(cornerTree?.allWindowIDs ?? []), [2, 3])
    }

    func testStillReconstructsTiledLayoutWithVacatedQuarterSlot() {
        // Left half occupied; right half has top empty and bottom occupied (3 edges flush)
        let windows = [
            WindowCandidate(windowID: 1, frame: CGRect(x: 0, y: 25, width: 800, height: 975)),
            WindowCandidate(windowID: 2, frame: CGRect(x: 800, y: 513, width: 800, height: 487)),
        ]
        let tree = LayoutReconstructor.reconstruct(windows: windows, in: screen)
        XCTAssertNotNil(tree)
        XCTAssertEqual(Set(tree?.allWindowIDs ?? []), [1, 2])
        let emptyLeaves = tree!.leafPlacements(in: screen).filter(\.isEmpty)
        XCTAssertEqual(emptyLeaves.count, 1)
        XCTAssertEqual(emptyLeaves[0].frame, CGRect(x: 800, y: 25, width: 800, height: 488))
    }
}
