import CoreGraphics
import XCTest
@testable import SeamstressCore

final class FrameCoalescerTests: XCTestCase {
    func testCoalescesFramesWhileInFlightAndKeepsLatestOnly() {
        var coalescer = PerPIDFrameCoalescer()

        let first = coalescer.enqueue(windowID: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(first?.first?.1.width, 500)
        XCTAssertTrue(coalescer.isBusy)

        // Three rapid frames arrive while the first AX write is in flight
        XCTAssertNil(coalescer.enqueue(windowID: 1, frame: CGRect(x: 0, y: 0, width: 510, height: 800)))
        XCTAssertNil(coalescer.enqueue(windowID: 1, frame: CGRect(x: 0, y: 0, width: 520, height: 800)))
        XCTAssertNil(coalescer.enqueue(windowID: 1, frame: CGRect(x: 0, y: 0, width: 545, height: 800)))
        XCTAssertNil(coalescer.enqueue(windowID: 2, frame: CGRect(x: 545, y: 0, width: 455, height: 800)))

        // Completing the first write pops only the latest frame for each window
        let next = coalescer.completeCurrent()
        XCTAssertEqual(next?.count, 2)
        XCTAssertEqual(next?[0].0, 1)
        XCTAssertEqual(next?[0].1.width, 545)
        XCTAssertEqual(next?[1].0, 2)
        XCTAssertEqual(next?[1].1.width, 455)

        // Completing with no newer frames transitions back to idle
        XCTAssertNil(coalescer.completeCurrent())
        XCTAssertFalse(coalescer.isBusy)
    }
}
