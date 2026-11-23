import Cocoa
import CoreGraphics
import Foundation
import SeamstressCore

struct DisplayInfo: Equatable {
    let displayID: CGDirectDisplayID
    let uuid: String
    let localizedName: String
    /// Full display bounds in CG coordinates (top-left origin).
    let fullFrameCG: CGRect
    /// Usable display bounds excluding menu bar & Dock, in CG coordinates.
    let usableFrameCG: CGRect
    /// Active native Space ID on this display.
    let activeSpaceID: SpaceID

    var spaceKey: SpaceKey {
        SpaceKey(displayUUID: uuid, spaceID: activeSpaceID)
    }

    /// True when `frame` covers the full display including the menu bar (native macOS fullscreen).
    func isNativeFullscreen(_ frame: CGRect) -> Bool {
        fullFrameCG.height > usableFrameCG.height + 10
            && abs(frame.width - fullFrameCG.width) <= 2
            && abs(frame.height - fullFrameCG.height) <= 2
    }
}

/// Caches connected displays, `primaryScreenHeight`, display UUIDs, and active native Space IDs.
/// Refreshes automatically on display parameter changes and native Space switches.
@MainActor
final class DisplayObserver {
    private(set) var primaryScreenHeight: CGFloat = 0
    private(set) var displays: [DisplayInfo] = []

    var onDisplaysOrSpacesChanged: ((_ topologyChanged: Bool) -> Void)?
    /// Called when the user session becomes inactive (screen locked, displays slept, or system sleeping)
    /// or active again (woke / unlocked).
    var onSessionActivityChanged: ((_ isActive: Bool) -> Void)?

    private var ncObservers: [NSObjectProtocol] = []
    private var wsObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var isSystemAsleep = false
    private var areScreensAsleep = false
    private var isLockedFromNotification = false

    /// True while the screen is locked, the system is sleeping, or all displays are asleep.
    /// Queries live CG session/display state in addition to notifications so launches that
    /// happen while the screen is already locked or dark are detected immediately.
    var isSessionInactive: Bool {
        if isSystemAsleep || areScreensAsleep || isLockedFromNotification {
            return true
        }
        if Self.isScreenLockedLive() {
            return true
        }
        if !displays.isEmpty && displays.allSatisfy({ CGDisplayIsAsleep($0.displayID) != 0 }) {
            return true
        }
        return false
    }

    func isDisplayAsleep(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsAsleep(displayID) != 0
    }

    init() {
        refresh()
    }

    func startObserving() {
        guard ncObservers.isEmpty && wsObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        ncObservers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let changed = self.refresh()
                self.onDisplaysOrSpacesChanged?(changed)
            }
        })

        wsObservers.append(ws.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.refresh()
                self.onDisplaysOrSpacesChanged?(false)
            }
        })

        wsObservers.append(ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSystemAsleep = true
                self.onSessionActivityChanged?(false)
            }
        })

        wsObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.areScreensAsleep = true
                self.onSessionActivityChanged?(false)
            }
        })

        wsObservers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSystemAsleep = false
                self.handleSessionResumed()
            }
        })

        wsObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.areScreensAsleep = false
                self.handleSessionResumed()
            }
        })

        distributedObservers.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLockedFromNotification = true
                self.onSessionActivityChanged?(false)
            }
        })

        distributedObservers.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLockedFromNotification = false
                self.handleSessionResumed()
            }
        })
    }

    private func handleSessionResumed() {
        _ = refresh()
        if !isSessionInactive {
            onSessionActivityChanged?(true)
        }
        onDisplaysOrSpacesChanged?(true)
    }

    func stopObserving() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        for obs in ncObservers {
            nc.removeObserver(obs)
        }
        ncObservers.removeAll()
        for obs in wsObservers {
            ws.removeObserver(obs)
        }
        wsObservers.removeAll()
        for obs in distributedObservers {
            dnc.removeObserver(obs)
        }
        distributedObservers.removeAll()
        isSystemAsleep = false
        areScreensAsleep = false
        isLockedFromNotification = false
    }

    /// Refreshes cached screens and active Space IDs. Returns true if display frames changed.
    @discardableResult
    func refresh() -> Bool {
        let screens = NSScreen.screens
        let primaryHeight = (screens.first(where: { $0.frame.origin == .zero }) ?? screens.first)?.frame.height ?? 0
        primaryScreenHeight = primaryHeight

        let activeSpaces = SkyLightBridge.shared.activeSpaceIDsByDisplay()
        // When "Displays have separate Spaces" is off, macOS reports one "Main" entry.
        let mainSpaceFallback = activeSpaces["Main"]

        let previousFrames = displays.map { ($0.uuid, $0.usableFrameCG) }
        var next: [DisplayInfo] = []

        for screen in screens {
            guard let screenNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(screenNum.uint32Value)
            let uuid = Self.displayUUID(for: displayID)
            let fullCG = CoordinateSpace.cgRect(fromNS: screen.frame, primaryHeight: primaryHeight)
            let usableCG = CoordinateSpace.cgRect(fromNS: screen.visibleFrame, primaryHeight: primaryHeight)
            let spaceID = activeSpaces[uuid] ?? mainSpaceFallback ?? 1

            next.append(DisplayInfo(
                displayID: displayID,
                uuid: uuid,
                localizedName: screen.localizedName,
                fullFrameCG: fullCG,
                usableFrameCG: usableCG,
                activeSpaceID: spaceID
            ))
        }

        displays = next
        let nextFrames = next.map { ($0.uuid, $0.usableFrameCG) }
        if previousFrames.count != nextFrames.count { return true }
        for (a, b) in zip(previousFrames, nextFrames) {
            if a.0 != b.0 || a.1 != b.1 { return true }
        }
        return false
    }

    func display(containing cgPoint: CGPoint) -> DisplayInfo? {
        if let exact = displays.first(where: { $0.fullFrameCG.contains(cgPoint) }) {
            return exact
        }
        return nil
    }

    func display(for spaceKey: SpaceKey) -> DisplayInfo? {
        displays.first(where: { $0.spaceKey == spaceKey })
    }

    func usableBounds(for spaceKey: SpaceKey) -> CGRect? {
        display(for: spaceKey)?.usableFrameCG
    }

    func activeSpaces() -> [(spaceKey: SpaceKey, bounds: CGRect)] {
        displays.map { ($0.spaceKey, $0.usableFrameCG) }
    }

    private static func isScreenLockedLive() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private static func displayUUID(for displayID: CGDirectDisplayID) -> String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, cfUUID) as String? {
            return str
        }
        return "DISPLAY-\(displayID)"
    }
}
