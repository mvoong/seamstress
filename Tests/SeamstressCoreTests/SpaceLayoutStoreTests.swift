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

    func testDraggingWindowFromVerticalSplitToTopTJunctionConvertsToHorizontalSplit() {
        let store = SpaceLayoutStore()
        let p1 = store.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p1, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: bounds)
        let p2 = store.planDrop(pointer: CGPoint(x: 900, y: 400), draggedWindowID: 2, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p2, draggedWindowID: 2, preDragFrame: .zero, boundsForSpace: bounds)

        // Drag window 1 to the top T-junction (500, 10) of [1 | 2] -> becomes [1 / 2]
        let tPlan = store.planDrop(pointer: CGPoint(x: 500, y: 10), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        let commit = store.commitDrop(tPlan, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: bounds)

        XCTAssertEqual(commit.framesToApply[1], CGRect(x: 0, y: 0, width: 1000, height: 400))
        XCTAssertEqual(commit.framesToApply[2], CGRect(x: 0, y: 400, width: 1000, height: 400))
    }

    func testDetachUndoSnapshotRestoresPreDetachLayoutForLateOptionPress() {
        let store = SpaceLayoutStore()
        let p1 = store.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p1, draggedWindowID: 1, preDragFrame: CGRect(x: 50, y: 50, width: 400, height: 300), boundsForSpace: bounds)
        let p2 = store.planDrop(pointer: CGPoint(x: 900, y: 400), draggedWindowID: 2, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p2, draggedWindowID: 2, preDragFrame: .zero, boundsForSpace: bounds)

        // Detach window 1 without Option -> 2 expands to full screen
        let detached = store.detachByUserDrag(windowID: 1, currentFrame: CGRect(x: 0, y: 0, width: 500, height: 800), cursor: CGPoint(x: 200, y: 20))!
        XCTAssertFalse(store.isTiled(1))
        XCTAssertEqual(store.frames(for: spaceA, screenBounds: boundsA), [2: boundsA])

        // User presses Option within grace window -> restore snapshot so 1 and 2 can swap
        XCTAssertTrue(store.restoreDetachSnapshot(detached.undo))
        XCTAssertTrue(store.isTiled(1))
        XCTAssertEqual(store.frames(for: spaceA, screenBounds: boundsA)[1], CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(store.frames(for: spaceA, screenBounds: boundsA)[2], CGRect(x: 500, y: 0, width: 500, height: 800))
    }

    func testManualResizeDetachesAndExpandsSibling() {
        let store = SpaceLayoutStore()
        let p1 = store.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p1, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: bounds)
        let p2 = store.planDrop(pointer: CGPoint(x: 900, y: 400), draggedWindowID: 2, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p2, draggedWindowID: 2, preDragFrame: .zero, boundsForSpace: bounds)

        XCTAssertEqual(store.detachByManualResize(windowID: 1), spaceA)
        XCTAssertFalse(store.isTiled(1))
        XCTAssertEqual(store.frames(for: spaceA, screenBounds: boundsA), [2: boundsA])
    }

    func testPlanDropDistinguishesCrossMonitorSwapFromFloatingReplace() {
        let store = SpaceLayoutStore()
        let p1 = store.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p1, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: bounds)
        let p2 = store.planDrop(pointer: CGPoint(x: 1600, y: 400), draggedWindowID: 2, targetSpace: spaceB, screenBounds: boundsB)!
        _ = store.commitDrop(p2, draggedWindowID: 2, preDragFrame: .zero, boundsForSpace: bounds)

        // Tiled window 1 dragged to center of window 2 on spaceB -> .swap
        let crossSwap = store.planDrop(pointer: CGPoint(x: 1600, y: 400), draggedWindowID: 1, targetSpace: spaceB, screenBounds: boundsB)
        XCTAssertEqual(crossSwap?.previewKind, .swap)

        // Floating window 3 dragged to center of window 2 on spaceB -> .replace
        let floatingReplace = store.planDrop(pointer: CGPoint(x: 1600, y: 400), draggedWindowID: 3, targetSpace: spaceB, screenBounds: boundsB)
        XCTAssertEqual(floatingReplace?.previewKind, .replace)
    }

    func testEqualizeSplitsInStore() {
        let store = SpaceLayoutStore()
        XCTAssertNil(store.equalizeSplits(in: spaceA, screenBounds: boundsA))

        let p1 = store.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p1, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: bounds)
        let p2 = store.planDrop(pointer: CGPoint(x: 900, y: 400), draggedWindowID: 2, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p2, draggedWindowID: 2, preDragFrame: .zero, boundsForSpace: bounds)

        let splitID = store.tree(for: spaceA).root.id
        _ = store.updateSeamRatio(spaceKey: spaceA, splitID: splitID, ratio: 0.25, screenBounds: boundsA)
        XCTAssertEqual(store.frames(for: spaceA, screenBounds: boundsA)[1]?.width, 250)

        let equalized = store.equalizeSplits(in: spaceA, screenBounds: boundsA)
        XCTAssertEqual(equalized?[1], CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(equalized?[2], CGRect(x: 500, y: 0, width: 500, height: 800))

        // Already equalized -> nil
        XCTAssertNil(store.equalizeSplits(in: spaceA, screenBounds: boundsA))
    }

    func testAdoptedFullScreenWindowDetachUsesFallbackFloatingSize() {
        let store = SpaceLayoutStore()
        var singleTree = LayoutTree()
        singleTree.fillEmpty(leafID: singleTree.root.id, with: 10)
        store.adoptReconstructedTree(singleTree, for: spaceA)

        // Full-screen adopted window (>= 85% of screenBounds) gets sensible fallback floating size
        let detached = store.detachByUserDrag(
            windowID: 10,
            currentFrame: boundsA,
            cursor: CGPoint(x: 500, y: 20),
            screenBounds: boundsA
        )
        XCTAssertNotNil(detached?.restoredFrame)
        XCTAssertEqual(
            detached?.restoredFrame?.size,
            CGSize(width: min(960, boundsA.width * 0.65), height: min(700, boundsA.height * 0.72))
        )

        // Half-screen adopted window (< 85% of screenBounds) keeps restoredFrame = nil
        var splitTree = LayoutTree()
        splitTree.fillEmpty(leafID: splitTree.root.id, with: 20)
        splitTree.splitOccupied(leafID: splitTree.leafID(for: 20)!, edge: .right, with: 21)
        store.adoptReconstructedTree(splitTree, for: spaceB)

        let halfFrame = CGRect(x: 1000, y: 0, width: 600, height: 800)
        let halfDetached = store.detachByUserDrag(
            windowID: 20,
            currentFrame: halfFrame,
            cursor: CGPoint(x: 1300, y: 20),
            screenBounds: boundsB
        )
        XCTAssertNotNil(halfDetached)
        XCTAssertNil(halfDetached?.restoredFrame)
    }

    func testSavedFloatingFramesSnapshotAndRestoreOnlyFillsMissingEntries() {
        let store1 = SpaceLayoutStore()
        let frame1 = CGRect(x: 50, y: 60, width: 520, height: 420)
        let p1 = store1.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store1.commitDrop(p1, draggedWindowID: 1, preDragFrame: frame1, boundsForSpace: bounds)

        let snapshot = store1.savedFloatingFramesSnapshot()
        XCTAssertEqual(snapshot, [1: frame1])

        let store2 = SpaceLayoutStore()
        let newerFrame1 = CGRect(x: 10, y: 10, width: 700, height: 500)
        let frame2 = CGRect(x: 200, y: 200, width: 600, height: 450)
        let p1New = store2.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store2.commitDrop(p1New, draggedWindowID: 1, preDragFrame: newerFrame1, boundsForSpace: bounds)

        store2.restoreSavedFloatingFrames([1: frame1, 2: frame2])
        // Existing entry for 1 is preserved; missing entry for 2 is filled
        XCTAssertEqual(store2.savedFloatingFrame(for: 1), newerFrame1)
        XCTAssertEqual(store2.savedFloatingFrame(for: 2), frame2)
    }

    func testRestoreSeamRatiosRevertsPreDragLayout() {
        let store = SpaceLayoutStore()
        let p1 = store.planDrop(pointer: CGPoint(x: 500, y: 400), draggedWindowID: 1, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p1, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: bounds)
        let p2 = store.planDrop(pointer: CGPoint(x: 900, y: 400), draggedWindowID: 2, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p2, draggedWindowID: 2, preDragFrame: .zero, boundsForSpace: bounds)
        let p3 = store.planDrop(pointer: CGPoint(x: 750, y: 750), draggedWindowID: 3, targetSpace: spaceA, screenBounds: boundsA)!
        _ = store.commitDrop(p3, draggedWindowID: 3, preDragFrame: .zero, boundsForSpace: bounds)

        let seamsBefore = store.visibleSeams(for: [(spaceA, boundsA)])
        let savedRatios = Dictionary(uniqueKeysWithValues: seamsBefore.map { ($0.splitID, $0.ratio) })
        let framesBefore = store.frames(for: spaceA, screenBounds: boundsA)

        // Drag both seams away from 0.5
        for seam in seamsBefore {
            _ = store.updateSeamRatio(spaceKey: spaceA, splitID: seam.splitID, ratio: 0.72, screenBounds: boundsA)
        }
        XCTAssertNotEqual(store.frames(for: spaceA, screenBounds: boundsA), framesBefore)

        // Escape cancel restores original ratios and frames
        let restoredFrames = store.restoreSeamRatios(savedRatios, in: spaceA, screenBounds: boundsA)
        XCTAssertEqual(restoredFrames, framesBefore)
        XCTAssertEqual(store.frames(for: spaceA, screenBounds: boundsA), framesBefore)
    }

    func testCollapseImpossibleEmptySplitsRemovesPhantomInnerSeamAfterMinSizeLearned() {
        let store = SpaceLayoutStore()
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 950)
        let laptopBounds: (SpaceKey) -> CGRect? = { $0 == self.spaceA ? laptop : nil }

        // Put window 1 on left half, window 2 on right half, then shrink window 1 to left quarter
        // BEFORE its minimum size is known (simulating an app with undisclosed min width).
        let p1 = store.planDrop(pointer: CGPoint(x: 756, y: 475), draggedWindowID: 1, targetSpace: spaceA, screenBounds: laptop)!
        _ = store.commitDrop(p1, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: laptopBounds)
        let p2 = store.planDrop(pointer: CGPoint(x: 1450, y: 475), draggedWindowID: 2, targetSpace: spaceA, screenBounds: laptop)!
        _ = store.commitDrop(p2, draggedWindowID: 2, preDragFrame: .zero, boundsForSpace: laptopBounds)
        let pShrink = store.planDrop(pointer: CGPoint(x: 20, y: 475), draggedWindowID: 1, targetSpace: spaceA, screenBounds: laptop)!
        _ = store.commitDrop(pShrink, draggedWindowID: 1, preDragFrame: .zero, boundsForSpace: laptopBounds)

        // Before learning min size, there are 2 vertical seams (outer 50% + inner 25%).
        XCTAssertEqual(store.visibleSeams(for: [(spaceA, laptop)]).count, 2)

        // Learn settled min width of 760px for window 1 and reconcile impossible empty splits.
        store.recordMinimumSize(CGSize(width: 760, height: 512), for: 1)
        let updated = store.collapseImpossibleEmptySplits(in: spaceA, screenBounds: laptop)
        XCTAssertNotNil(updated)

        // Phantom inner seam is gone; only the outer 50% seam remains and window 1 fills the left half.
        XCTAssertEqual(store.visibleSeams(for: [(spaceA, laptop)]).count, 1)
        XCTAssertEqual(updated?[1]?.width, 756)
        XCTAssertEqual(updated?[2]?.width, 756)
    }
}
