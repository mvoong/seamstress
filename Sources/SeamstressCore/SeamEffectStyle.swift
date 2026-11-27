import CoreGraphics
import Foundation

/// Visual style for Seamstress's flush seam and `┼` intersection highlight overlay.
public enum SeamEffectStyle: String, CaseIterable, Identifiable, Equatable, Sendable {
    /// Spring-physics taut bowstring that flexes crisply with drag motion and snaps straight on detents.
    case elastic
    /// Iridescent liquid-glass chromatic ribbon with cursor-lit sheen and detent shockwaves.
    case prism
    /// Minimal flat accent hairline and grip pill (pure Core Animation, no Metal).
    case classic

    public var id: String { rawValue }

    public static let defaultStyle: SeamEffectStyle = .elastic
    public static let userDefaultsKey = "seamstress.seamEffectStyle"

    public static func fromStoredValue(_ raw: String?) -> SeamEffectStyle {
        guard let raw, let style = SeamEffectStyle(rawValue: raw) else {
            return defaultStyle
        }
        return style
    }

    public var displayName: String {
        switch self {
        case .elastic: return "Elastic"
        case .prism: return "Prism"
        case .classic: return "Classic"
        }
    }

    public var subtitle: String {
        switch self {
        case .elastic: return "Snappy spring-physics cord that flexes as you drag"
        case .prism: return "Iridescent sheen with cursor glow & detent ripples"
        case .classic: return "Minimal system accent hairline and grip pill"
        }
    }

    public var usesMetal: Bool {
        self != .classic
    }

    /// Shader mode index consumed by `MetalSeamView`.
    public var shaderModeIndex: UInt32 {
        switch self {
        case .elastic: return 0
        case .prism: return 1
        case .classic: return 0
        }
    }

    /// Overlay panel thickness (in points) perpendicular to the seam axis.
    /// Kept tight to minimize GPU fragment work while giving glow and bowing room.
    public var envelopeThickness: CGFloat {
        switch self {
        case .elastic: return 22
        case .prism: return 20
        case .classic: return 10
        }
    }
}

/// Crisp, tightly damped 1D harmonic spring used to drive elastic cord flex and detent vibrations.
public struct SeamElasticSpring: Equatable, Sendable {
    public private(set) var displacement: CGFloat = 0
    public private(set) var velocity: CGFloat = 0

    /// Maximum lateral deflection in points (kept crisp so the cord never feels sluggish).
    public var maxDisplacement: CGFloat = 5.5
    /// High stiffness for snappy response and fast settle.
    public var stiffness: CGFloat = 780
    /// Damping coefficient (slight underdamping for a crisp tactile pluck).
    public var damping: CGFloat = 34

    public init(maxDisplacement: CGFloat = 5.5, stiffness: CGFloat = 780, damping: CGFloat = 34) {
        self.maxDisplacement = maxDisplacement
        self.stiffness = stiffness
        self.damping = damping
    }

    /// Injects a velocity impulse from seam motion or a hover/snap pluck.
    public mutating func applyImpulse(_ deltaVelocity: CGFloat) {
        velocity += deltaVelocity
        let maxVel: CGFloat = 180
        velocity = max(-maxVel, min(maxVel, velocity))
    }

    /// Integrates one frame step toward `target`.
    public mutating func step(dt rawDT: CGFloat, target: CGFloat = 0) {
        let dt = max(0, min(rawDT, 1.0 / 30.0))
        guard dt > 0 else { return }

        let clampedTarget = max(-maxDisplacement, min(maxDisplacement, target))
        let accel = -stiffness * (displacement - clampedTarget) - damping * velocity
        velocity += accel * dt
        displacement += velocity * dt

        if displacement > maxDisplacement {
            displacement = maxDisplacement
            if velocity > 0 { velocity = -velocity * 0.2 }
        } else if displacement < -maxDisplacement {
            displacement = -maxDisplacement
            if velocity < 0 { velocity = -velocity * 0.2 }
        }

        if abs(displacement - clampedTarget) < 0.01 && abs(velocity) < 0.05 {
            displacement = clampedTarget
            velocity = 0
        }
    }

    public mutating func reset() {
        displacement = 0
        velocity = 0
    }
}
