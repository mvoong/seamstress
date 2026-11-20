import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation
import SeamstressCore

struct CGWindowSnapshot: Equatable {
    let windowID: WindowID
    let ownerPID: pid_t
    let bounds: CGRect
    let layer: Int
    let alpha: CGFloat
    let ownerName: String?
}

/// High-performance Accessibility & WindowServer bridge.
///
/// Design for responsiveness:
/// - Hit-testing, occlusion checks, and drag-movement detection use `CGWindowListCopyWindowInfo`
///   (~0.1 ms WindowServer reads, zero AX IPC).
/// - AX frame writes run off the main thread on **one dedicated serial queue per PID** fronted
///   by `PerPIDFrameCoalescer`, so a slow Electron/Java app never stalls the cursor or fast native apps.
/// - `AXEnhancedUserInterface` is toggled off per-PID across drag/commit batches to eliminate
///   Chrome/Electron spring-animation lag, and cleanly restored afterward.
final class AXWindowBridge {
    private let lock = NSLock()
    private var elementCache: [WindowID: (pid: pid_t, element: AXUIElement)] = [:]
    private var lastAppliedFrames: [WindowID: CGRect] = [:]
    private var pidQueues: [pid_t: DispatchQueue] = [:]
    private var pidCoalescers: [pid_t: PerPIDFrameCoalescer] = [:]
    private var batchEnhancedRestore: [pid_t: Bool] = [:]

    private let selfPID = ProcessInfo.processInfo.processIdentifier

    static let axTimeout: Float = 0.25

    // MARK: - WindowServer fast reads (zero AX IPC)

    /// Returns all on-screen normal-layer windows in front-to-back Z-order.
    func onScreenNormalWindows() -> [CGWindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result: [CGWindowSnapshot] = []
        result.reserveCapacity(list.count)

        for entry in list {
            guard let wid = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  pid != selfPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let alpha = entry[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            guard alpha > 0.01 else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            guard bounds.width >= 40, bounds.height >= 40 else { continue }
            result.append(CGWindowSnapshot(
                windowID: wid,
                ownerPID: pid,
                bounds: bounds,
                layer: layer,
                alpha: alpha,
                ownerName: entry[kCGWindowOwnerName as String] as? String
            ))
        }
        return result
    }

    /// Topmost normal window under `cgPoint` (ignoring Seamstress itself).
    func topWindow(at cgPoint: CGPoint) -> CGWindowSnapshot? {
        for win in onScreenNormalWindows() where win.bounds.contains(cgPoint) {
            return win
        }
        return nil
    }

    /// Fast single-window bounds lookup (~0.1ms, zero AX IPC).
    func windowBounds(windowID: WindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let entry = list.first,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        return CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )
    }

    /// Returns true if a non-participating floating window sits in front of `cgPoint`
    /// covering a seam belonging to `allowedWindowIDs`.
    func isSeamPointOccluded(_ cgPoint: CGPoint, allowedWindowIDs: Set<WindowID>) -> Bool {
        for win in onScreenNormalWindows() {
            if win.bounds.contains(cgPoint) {
                return !allowedWindowIDs.contains(win.windowID)
            }
        }
        // Desktop / empty slot underneath -> not occluded
        return false
    }

    // MARK: - AX element resolution & validation

    func pid(for windowID: WindowID) -> pid_t? {
        lock.lock()
        let cached = elementCache[windowID]?.pid
        lock.unlock()
        if let cached { return cached }
        return onScreenNormalWindows().first(where: { $0.windowID == windowID })?.ownerPID
    }

    func register(windowID: WindowID, pid: pid_t, element: AXUIElement? = nil) {
        if let element {
            lock.lock()
            elementCache[windowID] = (pid, element)
            lock.unlock()
        } else {
            _ = resolveElement(windowID: windowID, pid: pid)
        }
    }

    func forget(windowID: WindowID) {
        lock.lock()
        elementCache.removeValue(forKey: windowID)
        lastAppliedFrames.removeValue(forKey: windowID)
        lock.unlock()
    }

    /// Resolve and cache the `AXUIElement` for `(windowID, pid)`.
    func resolveElement(windowID: WindowID, pid: pid_t) -> AXUIElement? {
        lock.lock()
        if let cached = elementCache[windowID], cached.pid == pid {
            lock.unlock()
            return cached.element
        }
        lock.unlock()

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)

        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return nil
        }

        var matched: AXUIElement?
        for el in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(el, &wid) == .success, wid != 0 {
                lock.lock()
                elementCache[wid] = (pid, el)
                lock.unlock()
                if wid == windowID {
                    matched = el
                }
            }
        }
        return matched
    }

    /// Check if a window is a standard resizable window (skipping sheets, popovers, system dialogs).
    func isStandardTileableWindow(windowID: WindowID, pid: pid_t) -> Bool {
        guard let el = resolveElement(windowID: windowID, pid: pid) else { return false }
        AXUIElementSetMessagingTimeout(el, Self.axTimeout)

        var roleObj: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleObj) == .success,
           let role = roleObj as? String,
           role != (kAXWindowRole as String) {
            return false
        }

        var subroleObj: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleObj) == .success,
           let subrole = subroleObj as? String,
           subrole != (kAXStandardWindowSubrole as String) {
            return false
        }

        var resizable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &resizable) == .success,
           !resizable.boolValue {
            return false
        }
        return true
    }

    /// Read current AX frame (or fallback to CG bounds).
    func readAXFrame(windowID: WindowID, pid: pid_t) -> CGRect? {
        guard let el = resolveElement(windowID: windowID, pid: pid) else {
            return windowBounds(windowID: windowID)
        }
        return Self.readFrame(of: el) ?? windowBounds(windowID: windowID)
    }

    // MARK: - Live resize batching (AXEnhancedUserInterface + per-PID coalescing)

    /// Disable `AXEnhancedUserInterface` on involved PIDs once at the start of a seam drag.
    func beginLiveResizeBatch(pids: Set<pid_t>) {
        for pid in pids {
            let q = queue(for: pid)
            q.async { [weak self] in
                guard let self else { return }
                let wasEnabled = self.disableEnhancedUIIfNeeded(pid: pid)
                if wasEnabled {
                    self.lock.lock()
                    self.batchEnhancedRestore[pid] = true
                    self.lock.unlock()
                }
            }
        }
    }

    /// Enqueue live frames during a seam drag. Uses per-PID latest-frame coalescing so
    /// fast apps resize at 60Hz+ and slow apps never accumulate an IPC backlog.
    func enqueueLiveFrames(_ frames: [WindowID: CGRect]) {
        var grouped: [pid_t: [(WindowID, CGRect)]] = [:]
        for (wid, frame) in frames {
            guard let pid = pid(for: wid) else { continue }
            grouped[pid, default: []].append((wid, frame))
        }

        for (pid, updates) in grouped {
            lock.lock()
            var coalescer = pidCoalescers[pid] ?? PerPIDFrameCoalescer()
            let batchToRun = coalescer.enqueueBatch(updates)
            pidCoalescers[pid] = coalescer
            lock.unlock()

            if let batchToRun {
                dispatchCoalescedBatch(pid: pid, batch: batchToRun)
            }
        }
    }

    /// End a seam drag: flush final exact frames and restore `AXEnhancedUserInterface`.
    func endLiveResizeBatch(finalFrames: [WindowID: CGRect], involvedPIDs: Set<pid_t>) {
        var grouped: [pid_t: [(WindowID, CGRect)]] = [:]
        for (wid, frame) in finalFrames {
            guard let pid = pid(for: wid) else { continue }
            grouped[pid, default: []].append((wid, frame))
        }

        let allPIDs = involvedPIDs.union(grouped.keys)
        for pid in allPIDs {
            let finalBatch = grouped[pid] ?? []
            let q = queue(for: pid)
            q.async { [weak self] in
                guard let self else { return }
                // Reset coalescer for this PID so no stale mid-drag frame runs after final.
                self.lock.lock()
                self.pidCoalescers[pid]?.reset()
                let shouldRestore = self.batchEnhancedRestore.removeValue(forKey: pid) ?? false
                self.lock.unlock()

                for (wid, frame) in finalBatch {
                    self.writeFrameSync(windowID: wid, pid: pid, target: frame, crossMonitorSafe: false)
                }
                if shouldRestore {
                    self.restoreEnhancedUI(pid: pid)
                }
            }
        }
    }

    /// Apply discrete frames (Option-drag commit, detach restore, double-click collapse, display change).
    /// Runs in parallel per PID off the main thread, with `AXEnhancedUserInterface` temporarily disabled.
    func applyFrames(
        _ frames: [WindowID: CGRect],
        crossMonitorSafe: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        var grouped: [pid_t: [(WindowID, CGRect)]] = [:]
        for (wid, frame) in frames {
            guard let pid = pid(for: wid) else { continue }
            grouped[pid, default: []].append((wid, frame))
        }

        guard !grouped.isEmpty else {
            completion?()
            return
        }

        let group = DispatchGroup()
        for (pid, batch) in grouped {
            group.enter()
            let q = queue(for: pid)
            q.async { [weak self] in
                defer { group.leave() }
                guard let self else { return }
                let restore = self.disableEnhancedUIIfNeeded(pid: pid)
                for (wid, rect) in batch {
                    self.writeFrameSync(windowID: wid, pid: pid, target: rect, crossMonitorSafe: crossMonitorSafe)
                }
                if restore {
                    self.restoreEnhancedUI(pid: pid)
                }
            }
        }

        if let completion {
            group.notify(queue: .main, execute: completion)
        }
    }

    // MARK: - Internal per-PID dispatch

    private func dispatchCoalescedBatch(
        pid: pid_t,
        batch: [(WindowID, CGRect)]
    ) {
        let q = queue(for: pid)
        q.async { [weak self] in
            guard let self else { return }

            for (wid, target) in batch {
                self.writeFrameSync(windowID: wid, pid: pid, target: target, crossMonitorSafe: false)
            }

            self.lock.lock()
            var coalescer = self.pidCoalescers[pid] ?? PerPIDFrameCoalescer()
            let nextBatch = coalescer.completeCurrent()
            self.pidCoalescers[pid] = coalescer
            self.lock.unlock()

            if let nextBatch {
                self.dispatchCoalescedBatch(pid: pid, batch: nextBatch)
            }
        }
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let existing = pidQueues[pid] { return existing }
        let q = DispatchQueue(label: "com.example.seamstress.ax.pid.\(pid)", qos: .userInteractive)
        pidQueues[pid] = q
        return q
    }

    private func writeFrameSync(
        windowID: WindowID,
        pid: pid_t,
        target: CGRect,
        crossMonitorSafe: Bool
    ) {
        guard let el = resolveElement(windowID: windowID, pid: pid) else { return }
        AXUIElementSetMessagingTimeout(el, Self.axTimeout)

        var pos = target.origin
        var size = target.size
        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize, &size) else {
            return
        }

        lock.lock()
        let previous = lastAppliedFrames[windowID]
        lastAppliedFrames[windowID] = target
        lock.unlock()

        if crossMonitorSafe {
            // Resize -> Move -> Resize handles macOS per-screen size clamping when crossing displays
            _ = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sizeVal)
            let moveErr = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
            let sizeErr = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sizeVal)
            if moveErr == .invalidUIElement || sizeErr == .invalidUIElement {
                forget(windowID: windowID)
            }
        } else {
            // Shrinking: set Size BEFORE Position so moving a bottom/right window inward
            // never pushes (newOrigin + oldSize) past the Dock/screen edge and gets clamped.
            // Growing: set Position BEFORE Size so moving upward/leftward makes room first.
            let shrinking = previous.map {
                target.width < $0.width || target.height < $0.height
            } ?? false

            let err1: AXError
            let err2: AXError
            if shrinking {
                err1 = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sizeVal)
                err2 = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
            } else {
                err1 = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, posVal)
                err2 = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sizeVal)
            }
            if err1 == .invalidUIElement || err2 == .invalidUIElement {
                forget(windowID: windowID)
            }
        }
    }

    private static func readFrame(of element: AXUIElement) -> CGRect? {
        var posObj: AnyObject?
        var sizeObj: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posObj) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeObj) == .success,
              let posVal = posObj, let sizeVal = sizeObj,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        guard pos.x.isFinite, pos.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private func disableEnhancedUIIfNeeded(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value)
        guard err == .success, let boolVal = value as? Bool, boolVal else {
            return false
        }
        let setErr = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        return setErr == .success
    }

    private func restoreEnhancedUI(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
}
