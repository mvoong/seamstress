import CoreGraphics
import XCTest
@testable import SeamstressCore

final class SeamEffectStyleTests: XCTestCase {
    func testStoredValueRoundTripAndFallback() {
        for style in SeamEffectStyle.allCases {
            XCTAssertEqual(SeamEffectStyle.fromStoredValue(style.rawValue), style)
            XCTAssertFalse(style.displayName.isEmpty)
            XCTAssertFalse(style.subtitle.isEmpty)
        }
        XCTAssertEqual(SeamEffectStyle.fromStoredValue(nil), SeamEffectStyle.defaultStyle)
        XCTAssertEqual(SeamEffectStyle.fromStoredValue("stitch"), SeamEffectStyle.defaultStyle)
        XCTAssertEqual(SeamEffectStyle.fromStoredValue("unknown-style"), SeamEffectStyle.defaultStyle)
    }

    func testMetalUsageAndEnvelopeWidths() {
        XCTAssertTrue(SeamEffectStyle.elastic.usesMetal)
        XCTAssertTrue(SeamEffectStyle.prism.usesMetal)
        XCTAssertFalse(SeamEffectStyle.classic.usesMetal)

        for style in [SeamEffectStyle.elastic, .prism] {
            XCTAssertGreaterThan(style.envelopeThickness, SeamEffectStyle.classic.envelopeThickness)
        }
        XCTAssertGreaterThanOrEqual(SeamEffectStyle.elastic.envelopeThickness, SeamEffectStyle.prism.envelopeThickness)
    }

    func testUniqueShaderModeIndicesForMetalStyles() {
        let metalModes = SeamEffectStyle.allCases.filter(\.usesMetal).map(\.shaderModeIndex)
        XCTAssertEqual(Set(metalModes).count, 2)
    }

    func testElasticSpringDeflectsClampsAndSettles() {
        var spring = SeamElasticSpring(maxDisplacement: 5.5, stiffness: 780, damping: 34)
        XCTAssertEqual(spring.displacement, 0)

        spring.applyImpulse(140)
        var peak: CGFloat = 0
        for _ in 0..<180 {
            spring.step(dt: 1.0 / 60.0)
            peak = max(peak, abs(spring.displacement))
            XCTAssertLessThanOrEqual(abs(spring.displacement), spring.maxDisplacement + 0.001)
        }

        XCTAssertGreaterThan(peak, 1.0, "Impulse should produce visible bowing deflection")
        XCTAssertEqual(spring.displacement, 0, accuracy: 0.05, "Damped spring should settle back to 0")
        XCTAssertEqual(spring.velocity, 0, accuracy: 0.05)
    }

    func testElasticSpringResetClearsMotion() {
        var spring = SeamElasticSpring()
        spring.applyImpulse(90)
        spring.step(dt: 1.0 / 60.0)
        XCTAssertNotEqual(spring.displacement, 0)

        spring.reset()
        XCTAssertEqual(spring.displacement, 0)
        XCTAssertEqual(spring.velocity, 0)
    }
}
