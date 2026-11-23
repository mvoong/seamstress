import CoreGraphics
import Foundation

/// Stable cross-launch identifier for an application (e.g. `"bundle:com.apple.Safari"`).
public typealias AppKey = String

/// A candidate newly-created window observed from a relaunched application.
public struct LaunchedWindow: Equatable, Sendable {
    public let windowID: WindowID
    public let frame: CGRect
    public let spaceKey: SpaceKey?

    public init(windowID: WindowID, frame: CGRect, spaceKey: SpaceKey? = nil) {
        self.windowID = windowID
        self.frame = frame
        self.spaceKey = spaceKey
    }
}

/// Snapshot of a single Space's layout immediately before an application quit,
/// paired with the post-quit tree and revision used to verify the Space has not
/// changed since the application quit.
public struct SpaceQuitSnapshot: Equatable, Sendable {
    public let spaceKey: SpaceKey
    public let preQuitTree: LayoutTree
    public let quitWindowIDs: [WindowID]
    public let savedFloatingFrames: [WindowID: CGRect]
    public let expectedPostQuitTree: LayoutTree
    public let expectedRevision: UInt64

    public init(
        spaceKey: SpaceKey,
        preQuitTree: LayoutTree,
        quitWindowIDs: [WindowID],
        savedFloatingFrames: [WindowID: CGRect],
        expectedPostQuitTree: LayoutTree,
        expectedRevision: UInt64
    ) {
        self.spaceKey = spaceKey
        self.preQuitTree = preQuitTree
        self.quitWindowIDs = quitWindowIDs
        self.savedFloatingFrames = savedFloatingFrames
        self.expectedPostQuitTree = expectedPostQuitTree
        self.expectedRevision = expectedRevision
    }
}

/// Pending restore record for a quit application across all Spaces it occupied.
public struct AppQuitSnapshot: Equatable, Sendable {
    public let appKey: AppKey
    public let quitTimestamp: TimeInterval
    public let spaces: [SpaceQuitSnapshot]

    public var totalExpectedWindows: Int {
        spaces.reduce(0) { $0 + $1.quitWindowIDs.count }
    }

    public init(appKey: AppKey, quitTimestamp: TimeInterval, spaces: [SpaceQuitSnapshot]) {
        self.appKey = appKey
        self.quitTimestamp = quitTimestamp
        self.spaces = spaces
    }
}
