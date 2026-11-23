import CoreGraphics
import Foundation
import SeamstressCore

/// Persists pre-tiled floating window frames across Seamstress relaunches, filtering out
/// stale window IDs that are no longer live in WindowServer.
enum LayoutPersistence {
    private static let savedFloatingFramesKey = "seamstress.savedFloatingFrames"
    private static let maxPersistedFloatingFrames = 64

    static func loadSavedFloatingFrames() -> [WindowID: CGRect] {
        guard let stored = UserDefaults.standard.dictionary(forKey: savedFloatingFramesKey) as? [String: [Double]],
              !stored.isEmpty else {
            return [:]
        }
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var liveWindowIDs: Set<WindowID> = []
        liveWindowIDs.reserveCapacity(list.count)
        for entry in list {
            if let wid = entry[kCGWindowNumber as String] as? UInt32 {
                liveWindowIDs.insert(wid)
            }
        }

        var restored: [WindowID: CGRect] = [:]
        for (key, coords) in stored {
            guard let wid = WindowID(key),
                  liveWindowIDs.contains(wid),
                  coords.count == 4,
                  coords.allSatisfy(\.isFinite),
                  coords[2] > 0,
                  coords[3] > 0 else {
                continue
            }
            restored[wid] = CGRect(x: coords[0], y: coords[1], width: coords[2], height: coords[3])
        }
        return restored
    }

    static func saveFloatingFrames(_ snapshot: [WindowID: CGRect]) {
        if snapshot.isEmpty {
            UserDefaults.standard.removeObject(forKey: savedFloatingFramesKey)
            return
        }
        var encoded: [String: [Double]] = [:]
        encoded.reserveCapacity(min(snapshot.count, maxPersistedFloatingFrames))
        for (wid, rect) in snapshot.prefix(maxPersistedFloatingFrames) {
            encoded[String(wid)] = [
                Double(rect.origin.x),
                Double(rect.origin.y),
                Double(rect.size.width),
                Double(rect.size.height),
            ]
        }
        UserDefaults.standard.set(encoded, forKey: savedFloatingFramesKey)
    }
}
