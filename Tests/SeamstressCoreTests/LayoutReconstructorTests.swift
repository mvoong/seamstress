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
}
