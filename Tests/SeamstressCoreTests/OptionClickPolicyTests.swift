import CoreGraphics
import XCTest
@testable import SeamstressCore

final class OptionClickPolicyTests: XCTestCase {
    func testStripsOptionWhenClickingUnfocusedTiledWindow() {
        XCTAssertTrue(
            OptionClickPolicy.shouldStripOptionOnMouseDown(
                flags: .maskAlternate,
                clickedWindowID: 20,
                clickedOwnerPID: 200,
                frontmostPID: 100,
                tiledWindowIDs: [10, 20],
                tiledPIDs: [100, 200]
            )
        )
    }

    func testStripsOptionWhenClickingUnfocusedTiledWindowWhileFrontmostIsFloating() {
        XCTAssertTrue(
            OptionClickPolicy.shouldStripOptionOnMouseDown(
                flags: .maskAlternate,
                clickedWindowID: 20,
                clickedOwnerPID: 200,
                frontmostPID: 100,
                tiledWindowIDs: [20],
                tiledPIDs: [200]
            )
        )
    }

    func testStripsOptionWhenClickingUnfocusedFloatingWindowWhileFrontmostIsTiled() {
        XCTAssertTrue(
            OptionClickPolicy.shouldStripOptionOnMouseDown(
                flags: .maskAlternate,
                clickedWindowID: 30,
                clickedOwnerPID: 300,
                frontmostPID: 100,
                tiledWindowIDs: [10],
                tiledPIDs: [100]
            )
        )
    }

    func testDoesNotStripOptionWhenClickingAlreadyFocusedApp() {
        XCTAssertFalse(
            OptionClickPolicy.shouldStripOptionOnMouseDown(
                flags: .maskAlternate,
                clickedWindowID: 10,
                clickedOwnerPID: 100,
                frontmostPID: 100,
                tiledWindowIDs: [10, 20],
                tiledPIDs: [100, 200]
            )
        )
    }

    func testDoesNotStripOptionWhenNeitherAppIsTiled() {
        XCTAssertFalse(
            OptionClickPolicy.shouldStripOptionOnMouseDown(
                flags: .maskAlternate,
                clickedWindowID: 30,
                clickedOwnerPID: 300,
                frontmostPID: 400,
                tiledWindowIDs: [10, 20],
                tiledPIDs: [100, 200]
            )
        )
    }

    func testDoesNotStripWhenCommandOrControlAlsoHeld() {
        XCTAssertFalse(
            OptionClickPolicy.shouldStripOptionOnMouseDown(
                flags: [.maskAlternate, .maskCommand],
                clickedWindowID: 20,
                clickedOwnerPID: 200,
                frontmostPID: 100,
                tiledWindowIDs: [10, 20],
                tiledPIDs: [100, 200]
            )
        )
        XCTAssertFalse(
            OptionClickPolicy.shouldStripOptionOnMouseDown(
                flags: [.maskAlternate, .maskControl],
                clickedWindowID: 20,
                clickedOwnerPID: 200,
                frontmostPID: 100,
                tiledWindowIDs: [10, 20],
                tiledPIDs: [100, 200]
            )
        )
    }

    func testDoesNotStripWithoutOptionOrWithoutTargetWindow() {
        XCTAssertFalse(
            OptionClickPolicy.shouldStripOptionOnMouseDown(
                flags: [.maskControl, .maskCommand],
                clickedWindowID: 20,
                clickedOwnerPID: 200,
                frontmostPID: 100,
                tiledWindowIDs: [10, 20],
                tiledPIDs: [100, 200]
            )
        )
        XCTAssertFalse(
            OptionClickPolicy.shouldStripOptionOnMouseDown(
                flags: .maskAlternate,
                clickedWindowID: nil,
                clickedOwnerPID: nil,
                frontmostPID: 100,
                tiledWindowIDs: [10, 20],
                tiledPIDs: [100, 200]
            )
        )
    }

    func testStrippingOptionClearsAlternateAndDeviceBitsOnly() {
        let raw = CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskShift.rawValue
            | 0x20 // NX_DEVICELALTKEYMASK
            | 0x40 // NX_DEVICERALTKEYMASK
        let stripped = OptionClickPolicy.strippingOption(from: CGEventFlags(rawValue: raw))

        XCTAssertFalse(stripped.contains(.maskAlternate))
        XCTAssertEqual(stripped.rawValue & 0x20, 0)
        XCTAssertEqual(stripped.rawValue & 0x40, 0)
        XCTAssertTrue(stripped.contains(.maskShift))
    }
}
