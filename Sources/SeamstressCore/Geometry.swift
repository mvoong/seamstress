import CoreGraphics
import Foundation

public typealias WindowID = UInt32
public typealias SpaceID = UInt64

/// Identifies a single native Space on a specific physical display.
public struct SpaceKey: Hashable, Sendable, CustomStringConvertible {
    public let displayUUID: String
    public let spaceID: SpaceID

    public init(displayUUID: String, spaceID: SpaceID) {
        self.displayUUID = displayUUID
        self.spaceID = spaceID
    }

    public var description: String { "\(displayUUID)#\(spaceID)" }
}

/// Direction of a BSP split divider.
/// - `.vertical`: side-by-side panes (left | right) separated by a vertical seam.
/// - `.horizontal`: stacked panes (top / bottom) separated by a horizontal seam.
public enum SplitAxis: Equatable, Hashable, Sendable {
    case vertical
    case horizontal
}

/// Which half of a cell a dragged window targets.
public enum SplitEdge: Equatable, Hashable, Sendable {
    case left
    case right
    case top
    case bottom

    public var axis: SplitAxis {
        switch self {
        case .left, .right: return .vertical
        case .top, .bottom: return .horizontal
        }
    }

    /// True when the incoming window goes into the `first` child (left or top).
    public var isFirstChild: Bool {
        switch self {
        case .left, .top: return true
        case .right, .bottom: return false
        }
    }
}

public enum CoordinateSpace {
    /// Convert a CoreGraphics rect (top-left origin, Y downward) to an AppKit rect
    /// (bottom-left origin, Y upward) anchored on the primary screen's height.
    public static func nsRect(fromCG rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    /// Convert an AppKit rect (bottom-left origin, Y upward) to a CoreGraphics rect
    /// (top-left origin, Y downward) anchored on the primary screen's height.
    public static func cgRect(fromNS rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    /// Convert a point between CG and NS coordinate spaces (self-inverse).
    public static func flipY(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

public extension CGRect {
    /// Split this rect flush (0px gap) along `axis` at `ratio` in (0, 1).
    /// Rounds the seam coordinate to an integer point so adjacent windows never
    /// have a 1pt overlap or 1pt sliver gap.
    func splitFlush(axis: SplitAxis, ratio: CGFloat) -> (first: CGRect, second: CGRect, seamPosition: CGFloat) {
        let clamped = min(max(ratio, 0.01), 0.99)
        switch axis {
        case .vertical:
            let firstWidth = (width * clamped).rounded()
            let secondWidth = max(0, width - firstWidth)
            let seamX = minX + firstWidth
            let first = CGRect(x: minX, y: minY, width: firstWidth, height: height)
            let second = CGRect(x: seamX, y: minY, width: secondWidth, height: height)
            return (first, second, seamX)
        case .horizontal:
            let firstHeight = (height * clamped).rounded()
            let secondHeight = max(0, height - firstHeight)
            let seamY = minY + firstHeight
            let first = CGRect(x: minX, y: minY, width: width, height: firstHeight)
            let second = CGRect(x: minX, y: seamY, width: width, height: secondHeight)
            return (first, second, seamY)
        }
    }

    /// Compute the restored floating frame for a tiled window being detached during a drag,
    /// keeping the window anchored naturally under the cursor so it never jumps away.
    static func restoredUnderCursor(
        savedSize: CGSize,
        currentFrame: CGRect,
        cursor: CGPoint
    ) -> CGRect {
        let relX: CGFloat
        if currentFrame.width > 1 {
            relX = min(max((cursor.x - currentFrame.minX) / currentFrame.width, 0.1), 0.9)
        } else {
            relX = 0.5
        }
        let offsetY = min(max(cursor.y - currentFrame.minY, 8), min(savedSize.height - 8, 36))
        let newX = (cursor.x - savedSize.width * relX).rounded()
        let newY = (cursor.y - offsetY).rounded()
        return CGRect(origin: CGPoint(x: newX, y: newY), size: savedSize)
    }

    /// Returns true when `point` lies on or within `margin` points of this rect's perimeter.
    /// Used to distinguish genuine manual edge/corner window resizes from transient size
    /// changes in the window interior (such as macOS's `Ctrl+Cmd` hold-to-drag lift pulse).
    func isPointNearEdge(_ point: CGPoint, margin: CGFloat = 16) -> Bool {
        let outer = insetBy(dx: -margin, dy: -margin)
        guard outer.contains(point) else { return false }
        let inner = insetBy(dx: margin, dy: margin)
        if inner.isNull || inner.width <= 0 || inner.height <= 0 {
            return true
        }
        return !inner.contains(point)
    }
}
