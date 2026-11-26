import CoreGraphics
import SeamstressCore
import XCTest

final class LayoutHistoryTests: XCTestCase {
    private let space1 = SpaceKey(displayUUID: "D1", spaceID: 1)
    private let space2 = SpaceKey(displayUUID: "D2", spaceID: 2)
    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func makeSplitStore(
        space: SpaceKey? = nil,
        left: WindowID = 100,
        right: WindowID = 200,
        ratio: CGFloat = 0.6
    ) -> SpaceLayoutStore {
        let s = space ?? space1
        let store = SpaceLayoutStore()

        // Drop `left` to fill, then drop `right` on right edge.
        let plan1 = store.planDrop(
            pointer: CGPoint(x: bounds.midX, y: bounds.midY),
            draggedWindowID: left,
            targetSpace: s,
            screenBounds: bounds
        )!
        _ = store.commitDrop(
            plan1,
            draggedWindowID: left,
            preDragFrame: CGRect(x: 100, y: 100, width: 700, height: 500),
            boundsForSpace: { _ in self.bounds }
        )

        let plan2 = store.planDrop(
            pointer: CGPoint(x: bounds.maxX - 120, y: bounds.midY),
            draggedWindowID: right,
            targetSpace: s,
            screenBounds: bounds
        )!
        _ = store.commitDrop(
            plan2,
            draggedWindowID: right,
            preDragFrame: CGRect(x: 300, y: 200, width: 640, height: 480),
            boundsForSpace: { _ in self.bounds }
        )

        if abs(ratio - 0.5) > 0.001,
           case .split(let splitID, _, _, _, _) = store.tree(for: s).root {
            _ = store.updateSeamRatio(spaceKey: s, splitID: splitID, ratio: ratio, screenBounds: bounds)
        }
        return store
    }

    func testDirectQuitAndRelaunchRestoresExactLayoutAndRatio() {
        let store = makeSplitStore(left: 100, right: 200, ratio: 0.65)
        let preQuitFrames = store.frames(for: space1, screenBounds: bounds)

        let quit = store.recordApplicationQuit(
            appKey: "bundle:com.test.right",
            remainingWindowIDs: [200],
            timestamp: 100.0
        )
        XCTAssertEqual(quit.affectedSpaces, [space1])
        XCTAssertNotNil(quit.snapshot)
        XCTAssertEqual(store.tree(for: space1).allWindowIDs, [100])
        XCTAssertEqual(store.frames(for: space1, screenBounds: bounds)[100], bounds)

        let restored = store.restoreQuitApplication(
            appKey: "bundle:com.test.right",
            launchedWindows: [LaunchedWindow(windowID: 300, frame: CGRect(x: 50, y: 50, width: 500, height: 400), spaceKey: space1)],
            activeSpaces: [space1],
            boundsForSpace: { _ in self.bounds }
        )
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.affectedSpaces, [space1])
        XCTAssertEqual(restored?.framesToApply[100], preQuitFrames[100])
        XCTAssertEqual(restored?.framesToApply[300], preQuitFrames[200])
        XCTAssertTrue(store.isTiled(300))
        XCTAssertFalse(store.isTiled(200))

        // Saved floating frame from before quit is preserved for the relaunched window.
        XCTAssertEqual(store.savedFloatingFrame(for: 300), CGRect(x: 300, y: 200, width: 640, height: 480))
    }

    func testStaggeredWindowDestroyedBeforeTerminateCoalescesIntoQuitSnapshot() {
        let store = makeSplitStore(left: 100, right: 200, ratio: 0.4)
        let preQuitFrames = store.frames(for: space1, screenBounds: bounds)

        // Simulate kAXUIElementDestroyedNotification arriving 40ms before didTerminateApplicationNotification.
        _ = store.handleWindowUnavailable(200, appKey: "bundle:com.test.right", timestamp: 50.000)
        XCTAssertEqual(store.tree(for: space1).allWindowIDs, [100])

        let quit = store.recordApplicationQuit(
            appKey: "bundle:com.test.right",
            remainingWindowIDs: [],
            timestamp: 50.040
        )
        XCTAssertTrue(quit.affectedSpaces.isEmpty)
        XCTAssertEqual(quit.snapshot?.spaces.count, 1)

        let restored = store.restoreQuitApplication(
            appKey: "bundle:com.test.right",
            launchedWindows: [LaunchedWindow(windowID: 300, frame: CGRect(x: 0, y: 0, width: 600, height: 400), spaceKey: space1)],
            activeSpaces: [space1],
            boundsForSpace: { _ in self.bounds }
        )
        XCTAssertEqual(restored?.framesToApply[100], preQuitFrames[100])
        XCTAssertEqual(restored?.framesToApply[300], preQuitFrames[200])
    }

    func testWindowClosedLongBeforeQuitDoesNotRestore() {
        let store = makeSplitStore(left: 100, right: 200, ratio: 0.5)

        // User closes window with Cmd+W at t = 10s, then quits app at t = 25s.
        _ = store.handleWindowUnavailable(200, appKey: "bundle:com.test.right", timestamp: 10.0)
        let quit = store.recordApplicationQuit(
            appKey: "bundle:com.test.right",
            remainingWindowIDs: [],
            timestamp: 25.0,
            coalesceWindow: 3.0
        )
        XCTAssertNil(quit.snapshot)
        XCTAssertNil(store.validQuitSnapshot(for: "bundle:com.test.right", activeSpaces: [space1]))
    }

    func testSpaceMutationAfterQuitInvalidatesRestore() {
        let store = makeSplitStore(left: 100, right: 200, ratio: 0.5)
        _ = store.recordApplicationQuit(
            appKey: "bundle:com.test.right",
            remainingWindowIDs: [200],
            timestamp: 100.0
        )
        XCTAssertNotNil(store.validQuitSnapshot(for: "bundle:com.test.right", activeSpaces: [space1]))

        // Tile another window into space1 after the app quit.
        let plan = store.planDrop(
            pointer: CGPoint(x: bounds.maxX - 40, y: bounds.midY),
            draggedWindowID: 300,
            targetSpace: space1,
            screenBounds: bounds
        )!
        _ = store.commitDrop(
            plan,
            draggedWindowID: 300,
            preDragFrame: CGRect(x: 10, y: 10, width: 500, height: 400),
            boundsForSpace: { _ in self.bounds }
        )

        XCTAssertNil(store.validQuitSnapshot(for: "bundle:com.test.right", activeSpaces: [space1]))
        let restored = store.restoreQuitApplication(
            appKey: "bundle:com.test.right",
            launchedWindows: [LaunchedWindow(windowID: 400, frame: CGRect(x: 0, y: 0, width: 500, height: 400), spaceKey: space1)],
            activeSpaces: [space1],
            boundsForSpace: { _ in self.bounds }
        )
        XCTAssertNil(restored)
        XCTAssertFalse(store.isTiled(400))
        XCTAssertEqual(Set(store.tree(for: space1).allWindowIDs), [100, 300])
    }

    func testSeamResizeAfterQuitInvalidatesRestore() {
        let store = makeSplitStore(left: 100, right: 200, ratio: 0.5)
        // Add a third window (300) so a seam still exists after 200 quits.
        let plan = store.planDrop(
            pointer: CGPoint(x: 200, y: bounds.maxY - 40),
            draggedWindowID: 300,
            targetSpace: space1,
            screenBounds: bounds
        )!
        _ = store.commitDrop(
            plan,
            draggedWindowID: 300,
            preDragFrame: CGRect(x: 0, y: 0, width: 500, height: 400),
            boundsForSpace: { _ in self.bounds }
        )

        _ = store.recordApplicationQuit(
            appKey: "bundle:com.test.right",
            remainingWindowIDs: [200],
            timestamp: 100.0
        )
        XCTAssertNotNil(store.validQuitSnapshot(for: "bundle:com.test.right", activeSpaces: [space1]))

        // Resize the remaining seam between 100 and 300.
        if case .split(let splitID, _, _, _, _) = store.tree(for: space1).root {
            _ = store.updateSeamRatio(spaceKey: space1, splitID: splitID, ratio: 0.7, screenBounds: bounds)
        } else {
            XCTFail("Expected remaining split after 200 quit")
        }

        XCTAssertNil(store.validQuitSnapshot(for: "bundle:com.test.right", activeSpaces: [space1]))
    }

    func testMultiWindowQuitCoalescesAndHandlesFullOrPartialRelaunch() {
        // Space has [100 | (200 / 201)] where 200 and 201 belong to the same app.
        let store = makeSplitStore(left: 100, right: 200, ratio: 0.5)
        let plan3 = store.planDrop(
            pointer: CGPoint(x: 1200, y: bounds.maxY - 40),
            draggedWindowID: 201,
            targetSpace: space1,
            screenBounds: bounds
        )!
        _ = store.commitDrop(
            plan3,
            draggedWindowID: 201,
            preDragFrame: CGRect(x: 0, y: 0, width: 500, height: 400),
            boundsForSpace: { _ in self.bounds }
        )
        let preQuitFrames = store.frames(for: space1, screenBounds: bounds)

        // 200 closes via AXDestroyed first, then 201 is still in store when didTerminate fires.
        _ = store.handleWindowUnavailable(200, appKey: "bundle:com.test.multi", timestamp: 20.000)
        let quit = store.recordApplicationQuit(
            appKey: "bundle:com.test.multi",
            remainingWindowIDs: [201],
            timestamp: 20.030
        )
        XCTAssertEqual(quit.snapshot?.totalExpectedWindows, 2)
        XCTAssertEqual(store.tree(for: space1).allWindowIDs, [100])

        // Relaunch with 2 windows: top (y=100) and bottom (y=600) should map to 200 and 201 respectively.
        let restored = store.restoreQuitApplication(
            appKey: "bundle:com.test.multi",
            launchedWindows: [
                LaunchedWindow(windowID: 301, frame: CGRect(x: 900, y: 600, width: 400, height: 300), spaceKey: space1),
                LaunchedWindow(windowID: 300, frame: CGRect(x: 900, y: 100, width: 400, height: 300), spaceKey: space1),
            ],
            activeSpaces: [space1],
            boundsForSpace: { _ in self.bounds }
        )
        XCTAssertEqual(restored?.framesToApply[100], preQuitFrames[100])
        XCTAssertEqual(restored?.framesToApply[300], preQuitFrames[200])
        XCTAssertEqual(restored?.framesToApply[301], preQuitFrames[201])
    }

    func testMultiWindowPartialRelaunchCollapsesUnreopenedSlot() {
        let store = makeSplitStore(left: 100, right: 200, ratio: 0.5)
        let plan3 = store.planDrop(
            pointer: CGPoint(x: 1200, y: bounds.maxY - 40),
            draggedWindowID: 201,
            targetSpace: space1,
            screenBounds: bounds
        )!
        _ = store.commitDrop(
            plan3,
            draggedWindowID: 201,
            preDragFrame: CGRect(x: 0, y: 0, width: 500, height: 400),
            boundsForSpace: { _ in self.bounds }
        )

        _ = store.recordApplicationQuit(
            appKey: "bundle:com.test.multi",
            remainingWindowIDs: [200, 201],
            timestamp: 30.0
        )

        // Only 1 window opens on relaunch -> fills the right half, collapses the second slot.
        let restored = store.restoreQuitApplication(
            appKey: "bundle:com.test.multi",
            launchedWindows: [LaunchedWindow(windowID: 300, frame: CGRect(x: 900, y: 100, width: 400, height: 300), spaceKey: space1)],
            activeSpaces: [space1],
            boundsForSpace: { _ in self.bounds }
        )
        XCTAssertEqual(restored?.framesToApply[100], CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(restored?.framesToApply[300], CGRect(x: 800, y: 0, width: 800, height: 1000))
        XCTAssertEqual(Set(store.tree(for: space1).allWindowIDs), [100, 300])
    }

    func testOnlyTiledWindowInSpaceRestoresWhenSpaceStaysEmpty() {
        let store = SpaceLayoutStore()
        // Place a single window on the left half (leaving right half empty).
        let plan = store.planDrop(
            pointer: CGPoint(x: 40, y: bounds.midY),
            draggedWindowID: 100,
            targetSpace: space1,
            screenBounds: bounds
        )!
        _ = store.commitDrop(
            plan,
            draggedWindowID: 100,
            preDragFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
            boundsForSpace: { _ in self.bounds }
        )
        let preQuitFrame = store.frames(for: space1, screenBounds: bounds)[100]

        _ = store.recordApplicationQuit(
            appKey: "bundle:com.test.solo",
            remainingWindowIDs: [100],
            timestamp: 10.0
        )
        XCTAssertTrue(store.tree(for: space1).isEmpty)

        let restored = store.restoreQuitApplication(
            appKey: "bundle:com.test.solo",
            launchedWindows: [LaunchedWindow(windowID: 200, frame: CGRect(x: 50, y: 50, width: 500, height: 400), spaceKey: space1)],
            activeSpaces: [space1],
            boundsForSpace: { _ in self.bounds }
        )
        XCTAssertEqual(restored?.framesToApply[200], preQuitFrame)
        XCTAssertEqual(store.tree(for: space1).allWindowIDs, [200])
    }

    func testMultiSpaceQuitRestoresOnlyUnchangedActiveSpace() {
        let store = makeSplitStore(space: space1, left: 100, right: 200, ratio: 0.5)
        // Also tile 201 (same app) on space2 alongside 101.
        let p1 = store.planDrop(
            pointer: CGPoint(x: bounds.midX, y: bounds.midY),
            draggedWindowID: 101,
            targetSpace: space2,
            screenBounds: bounds
        )!
        _ = store.commitDrop(p1, draggedWindowID: 101, preDragFrame: .zero, boundsForSpace: { _ in self.bounds })
        let p2 = store.planDrop(
            pointer: CGPoint(x: bounds.maxX - 40, y: bounds.midY),
            draggedWindowID: 201,
            targetSpace: space2,
            screenBounds: bounds
        )!
        _ = store.commitDrop(p2, draggedWindowID: 201, preDragFrame: .zero, boundsForSpace: { _ in self.bounds })

        _ = store.recordApplicationQuit(
            appKey: "bundle:com.test.dual",
            remainingWindowIDs: [200, 201],
            timestamp: 10.0
        )

        // Mutate space1 (detach 100); leave space2 untouched.
        _ = store.detachByManualResize(windowID: 100)

        let valid = store.validQuitSnapshot(for: "bundle:com.test.dual", activeSpaces: [space1, space2])
        XCTAssertEqual(valid?.spaces.map(\.spaceKey), [space2])

        let restored = store.restoreQuitApplication(
            appKey: "bundle:com.test.dual",
            launchedWindows: [LaunchedWindow(windowID: 301, frame: CGRect(x: 0, y: 0, width: 500, height: 400), spaceKey: space2)],
            activeSpaces: [space1, space2],
            boundsForSpace: { _ in self.bounds }
        )
        XCTAssertEqual(restored?.affectedSpaces, [space2])
        XCTAssertTrue(store.isTiled(301))
        XCTAssertEqual(store.spaceKey(for: 301), space2)
        XCTAssertTrue(store.tree(for: space1).isEmpty)
    }

    func testInactiveSpaceIsNotRestoredOnRelaunch() {
        let store = makeSplitStore(space: space1, left: 100, right: 200, ratio: 0.5)
        _ = store.recordApplicationQuit(
            appKey: "bundle:com.test.right",
            remainingWindowIDs: [200],
            timestamp: 10.0
        )

        // User switched to space2 before relaunching the app.
        XCTAssertNil(store.validQuitSnapshot(for: "bundle:com.test.right", activeSpaces: [space2]))
        let restored = store.restoreQuitApplication(
            appKey: "bundle:com.test.right",
            launchedWindows: [LaunchedWindow(windowID: 300, frame: CGRect(x: 0, y: 0, width: 500, height: 400), spaceKey: space2)],
            activeSpaces: [space2],
            boundsForSpace: { _ in self.bounds }
        )
        XCTAssertNil(restored)
        XCTAssertFalse(store.isTiled(300))
    }

    func testUnrelatedAppClosingBeforeTargetQuitIsNotIncludedInTargetSnapshot() {
        let store = makeSplitStore(left: 100, right: 200, ratio: 0.5)

        // App A (100) closes 0.5s before App B (200) quits.
        _ = store.handleWindowUnavailable(100, appKey: "bundle:com.test.left", timestamp: 10.0)
        _ = store.handleWindowUnavailable(200, appKey: "bundle:com.test.right", timestamp: 10.5)
        let quit = store.recordApplicationQuit(
            appKey: "bundle:com.test.right",
            remainingWindowIDs: [],
            timestamp: 10.55
        )
        XCTAssertEqual(quit.snapshot?.spaces.first?.quitWindowIDs, [200])
        // Pre-quit tree for App B should only contain 200 (full screen), not 100.
        XCTAssertEqual(quit.snapshot?.spaces.first?.preQuitTree.allWindowIDs, [200])
    }

    func testWindowIDReuseOnRelaunchSucceedsWithoutCollision() {
        let store = makeSplitStore(left: 100, right: 200, ratio: 0.5)
        _ = store.recordApplicationQuit(
            appKey: "bundle:com.test.right",
            remainingWindowIDs: [200],
            timestamp: 10.0
        )

        // WindowServer reuses the exact same WindowID 200 for the relaunched window.
        let restored = store.restoreQuitApplication(
            appKey: "bundle:com.test.right",
            launchedWindows: [LaunchedWindow(windowID: 200, frame: CGRect(x: 0, y: 0, width: 500, height: 400), spaceKey: space1)],
            activeSpaces: [space1],
            boundsForSpace: { _ in self.bounds }
        )
        XCTAssertNotNil(restored)
        XCTAssertTrue(store.isTiled(200))
        XCTAssertEqual(Set(store.tree(for: space1).allWindowIDs), [100, 200])
    }
}
