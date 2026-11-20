import ApplicationServices
import Cocoa
import Foundation
import SeamstressCore

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Safe dynamic bridge to private SkyLight/CGS functions that work with SIP enabled.
/// Used exclusively for read-only native Space queries and background cursor updates.
final class SkyLightBridge {
    static let shared = SkyLightBridge()

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?
    private typealias SetConnectionPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> CGError

    private let mainConnectionID: MainConnectionIDFn?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?
    private let setConnectionProperty: SetConnectionPropertyFn?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
            ?? UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT fallback

        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }

        self.mainConnectionID = sym("SLSMainConnectionID", as: MainConnectionIDFn.self)
            ?? sym("_CGSDefaultConnection", as: MainConnectionIDFn.self)
        self.copyManagedDisplaySpaces = sym("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
            ?? sym("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
        self.copySpacesForWindows = sym("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
            ?? sym("SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
        self.setConnectionProperty = sym("CGSSetConnectionProperty", as: SetConnectionPropertyFn.self)
            ?? sym("SLSSetConnectionProperty", as: SetConnectionPropertyFn.self)
    }

    /// Allow our background menu bar app to change the mouse cursor when hovering a flush seam.
    func enableBackgroundCursor() {
        guard let cidFn = mainConnectionID, let setProp = setConnectionProperty else { return }
        let cid = cidFn()
        _ = setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    /// Returns `[displayUUID: activeSpaceID]` for every connected display.
    /// Falls back to empty dictionary if SkyLight is unavailable.
    func activeSpaceIDsByDisplay() -> [String: SpaceID] {
        guard let cidFn = mainConnectionID,
              let copySpaces = copyManagedDisplaySpaces,
              let raw = copySpaces(cidFn()) as? [[String: Any]] else {
            return [:]
        }
        var result: [String: SpaceID] = [:]
        for display in raw {
            guard let uuid = display["Display Identifier"] as? String else { continue }
            if let current = display["Current Space"] as? [String: Any] {
                if let id = current["ManagedSpaceID"] as? UInt64 {
                    result[uuid] = id
                } else if let id = current["id64"] as? UInt64 {
                    result[uuid] = id
                } else if let num = current["ManagedSpaceID"] as? NSNumber {
                    result[uuid] = num.uint64Value
                }
            }
        }
        return result
    }

    /// Returns all Space IDs a given window currently belongs to.
    func spaceIDs(for windowID: WindowID) -> [SpaceID] {
        guard let cidFn = mainConnectionID,
              let copyWinSpaces = copySpacesForWindows else {
            return []
        }
        var wid = Int32(bitPattern: windowID)
        guard let cfNum = CFNumberCreate(nil, .sInt32Type, &wid) else { return [] }
        let arr = [cfNum] as CFArray
        // kCGSAllSpacesMask = 7
        guard let spaces = copyWinSpaces(cidFn(), 7, arr) as? [NSNumber] else { return [] }
        return spaces.map { $0.uint64Value }
    }
}
