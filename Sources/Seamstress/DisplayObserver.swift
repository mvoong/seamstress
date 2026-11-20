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
}

/// Caches connected displays, `primaryScreenHeight`, display UUIDs, and active native Space IDs.
/// Refreshes automatically on display parameter changes and native Space switches.
final class DisplayObserver {
    private(set) var primaryScreenHeight: CGFloat = 0
    private(set) var displays: [DisplayInfo] = []

    var onDisplaysOrSpacesChanged: ((_ topologyChanged: Bool) -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
    }

    func startObserving() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter

        observers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let changed = self.refresh()
            self.onDisplaysOrSpacesChanged?(changed)
        })

        observers.append(ws.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            _ = self.refresh()
            self.onDisplaysOrSpacesChanged?(false)
        })
    }

    func stopObserving() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        for obs in observers {
            nc.removeObserver(obs)
            ws.removeObserver(obs)
        }
        observers.removeAll()
    }

    /// Refreshes cached screens and active Space IDs. Returns true if display frames changed.
    @discardableResult
    func refresh() -> Bool {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
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

    private static func displayUUID(for displayID: CGDirectDisplayID) -> String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, cfUUID) as String? {
            return str
        }
        return "DISPLAY-\(displayID)"
    }
}
