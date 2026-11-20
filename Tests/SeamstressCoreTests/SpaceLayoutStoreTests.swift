import CoreGraphics
import XCTest
@testable import SeamstressCore

final class SpaceLayoutStoreTests: XCTestCase {
    private let spaceA = SpaceKey(displayUUID: "MAIN", spaceID: 1)
    private let spaceB = SpaceKey(displayUUID: "EXT", spaceID: 2)
    private let boundsA = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let boundsB = CGRect(x: 1000, y: 0, width: 1200, height: 800)

    private func bounds(for space: SpaceKey) -> CGRect? {
        space == spaceA ? boundsA : (space == spaceB ? boundsB : nil)
    }

    func testSameSpaceMoveToEmptySlotDoesNotLoseWindow() {
        let store = SpaceLayoutStore()
        // Place window 1 on left half (right half is empty)
        let plan1 = store.planDrop(pointer: CGPoint(x: 30, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(plan1, draggedWindowID: 1, preDragFrame: CGRect(x: 100, y: 100, width: 600, height: 500), boundsForSpace: bounds)
        XCTAssertEqual(store.frames(for: spaceA, screenBounds: boundsA)[1], CGRect(x: 0, y: 0, width: 500, height: 800))

        // Option-drag window 1 from left half into empty right half
        let plan2 = store.planDrop(pointer: CGPoint(x: 750, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        let result = store.commitDrop(plan2, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: bounds)

        XCTAssertTrue(store.isTiled(1))
        XCTAssertEqual(result.framesToApply[1], CGRect(x: 500, y: 0, width: 500, height: 800))
    }

    func testDetachRestoresSavedFloatingSizeUnderCursorAndExpandsSibling() {
        let store = SpaceLayoutStore()
        let original = CGRect(x: 200, y: 200, width: 640, height: 480)
        let plan1 = store.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(plan1, draggedWindowID: 1, preDragFrame: original, boundsForSpace: bounds)
        let plan2 = store.planDrop(pointer: CGPoint(x: 900, y: 400), draggedWindowID: 2, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(plan2, draggedWindowID: 2, preDragFrame: .zero, boundsForSpace: bounds)

        let leftHalf = CGRect(x: 0, y: 0, width: 500, height: 800)
        let detached = store.detachByUserDrag(windowID: 1, currentFrame: leftHalf, cursor: CGPoint(x: 250, y: 20))
        XCTAssertNotNil(detached)
        XCTAssertFalse(store.isTiled(1))
        XCTAssertEqual(detached?.restoredFrame?.size, original.size)
        // Sibling window 2 expands to fill the entire screen
        XCTAssertEqual(store.frames(for: spaceA, screenBounds: boundsA), [2: boundsA])
    }

    func testFloatingReplaceDisplacesTiledWindowAndRestoresItsFrame() {
        let store = SpaceLayoutStore()
        let saved1 = CGRect(x: 120, y: 140, width: 500, height: 400)
        let plan1 = store.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(plan1, draggedWindowID: 1, preDragFrame: saved1, boundsForSpace: bounds)

        // Drop floating window 2 onto center of window 1
        let plan2 = store.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 2, targetSpace: spaceA, screenBounds: boundsA)!
        let commit = store.commitDrop(plan2, draggedWindowID: 2, preDragFrame: CGRect(x: 0, y: 0, width: 400, height: 300), boundsForSpace: bounds)

        XCTAssertTrue(store.isTiled(2))
        XCTAssertFalse(store.isTiled(1))
        XCTAssertEqual(commit.framesToApply[2], boundsA)
        XCTAssertEqual(commit.detachedWindows[1], saved1)
    }

    func testCrossMonitorSwap() {
        let store = SpaceLayoutStore()
        let p1 = store.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p1, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: bounds)

        let p2 = store.planDrop(pointer: CGPoint(x: 1600, y: 400), draggedWindowID: 2, targetSpace: spaceB, screenBounds: boundsB)!
        _ = store.commitDrop(p2, draggedWindowID: 2, preDragFrame: .zero, boundsForSpace: bounds)

        // Swap window 1 onto center of window 2 on monitor B
        let swap = store.planDrop(pointer: CGPoint(x: 1600, y: 400), draggedWindowID: 1, targetSpace: spaceB, screenBounds: boundsB)!
        let result = store.commitDrop(swap, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: bounds)

        XCTAssertEqual(store.spaceKey(for: 1), spaceB)
        XCTAssertEqual(store.spaceKey(for: 2), spaceA)
        XCTAssertEqual(result.framesToApply[1], boundsB)
        XCTAssertEqual(result.framesToApply[2], boundsA)
    }
}
