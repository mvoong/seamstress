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

struct WindowAppInfo: Equatable {
    let pid: pid_t
    let appName: String?
    let icon: NSImage?
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
    private var tileableCache: Set<WindowID> = []
    private var lastAppliedFrames: [WindowID: CGRect] = [:]
    private var appKeyByPID: [pid_t: AppKey] = [:]
    private var appKeyByWindowID: [WindowID: AppKey] = [:]
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

    /// Stable cross-launch application key for quit/relaunch layout history.
    static func appKey(for app: NSRunningApplication) -> AppKey? {
        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
            return "bundle:\(bundleID)"
        }
        if let url = app.executableURL ?? app.bundleURL {
            return "url:\(url.path)"
        }
        if let name = app.localizedName, !name.isEmpty {
            return "name:\(name)"
        }
        return nil
    }

    func cacheAppKey(_ key: AppKey, for pid: pid_t) {
        lock.lock()
        appKeyByPID[pid] = key
        lock.unlock()
    }

    func appKey(for pid: pid_t) -> AppKey? {
        lock.lock()
        let cached = appKeyByPID[pid]
        lock.unlock()
        if let cached { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid),
              let key = Self.appKey(for: app) else {
            return nil
        }
        lock.lock()
        appKeyByPID[pid] = key
        lock.unlock()
        return key
    }

    func appKey(for windowID: WindowID) -> AppKey? {
        lock.lock()
        let cached = appKeyByWindowID[windowID]
        lock.unlock()
        if let cached { return cached }
        guard let pid = pid(for: windowID), let key = appKey(for: pid) else {
            return nil
        }
        lock.lock()
        appKeyByWindowID[windowID] = key
        lock.unlock()
        return key
    }

    func appInfo(for windowID: WindowID) -> WindowAppInfo? {
        guard let pid = pid(for: windowID) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return WindowAppInfo(pid: pid, appName: app?.localizedName, icon: app?.icon)
    }

    /// Bring `windowID` and its owning application to the front without blocking the main thread on AX IPC.
    func focusWindow(windowID: WindowID) {
        guard let pid = pid(for: windowID) else { return }

        if Thread.isMainThread {
            NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
        } else {
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
            }
        }

        let q = queue(for: pid)
        q.async { [weak self] in
            guard let self, let el = self.resolveElement(windowID: windowID, pid: pid) else { return }
            AXUIElementSetMessagingTimeout(el, Self.axTimeout)
            let raiseErr = AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            let mainErr = AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
            if raiseErr == .invalidUIElement || mainErr == .invalidUIElement {
                self.forget(windowID: windowID)
            }
        }
    }

    func registerAsync(windowID: WindowID, pid: pid_t) {
        lock.lock()
        let alreadyCached = elementCache[windowID]?.pid == pid
        lock.unlock()
        guard !alreadyCached else { return }
        queue(for: pid).async { [weak self] in
            _ = self?.resolveElement(windowID: windowID, pid: pid)
        }
    }

    func forget(windowID: WindowID) {
        lock.lock()
        elementCache.removeValue(forKey: windowID)
        tileableCache.remove(windowID)
        lastAppliedFrames.removeValue(forKey: windowID)
        appKeyByWindowID.removeValue(forKey: windowID)
        lock.unlock()
    }

    /// Evict all cached AX elements, frame history, queues, and coalescers for a terminated app.
    func evictTerminatedPID(_ pid: pid_t) {
        lock.lock()
        let deadIDs = elementCache.compactMap { $0.value.pid == pid ? $0.key : nil }
        for wid in deadIDs {
            elementCache.removeValue(forKey: wid)
            tileableCache.remove(wid)
            lastAppliedFrames.removeValue(forKey: wid)
            appKeyByWindowID.removeValue(forKey: wid)
        }
        appKeyByPID.removeValue(forKey: pid)
        pidQueues.removeValue(forKey: pid)
        pidCoalescers.removeValue(forKey: pid)
        batchEnhancedRestore.removeValue(forKey: pid)
        lock.unlock()
    }

    /// Resolve and cache the `AXUIElement` for `(windowID, pid)`.
    func resolveElement(windowID: WindowID, pid: pid_t, timeout: Float = AXWindowBridge.axTimeout) -> AXUIElement? {
        lock.lock()
        if let cached = elementCache[windowID], cached.pid == pid {
            lock.unlock()
            return cached.element
        }
        lock.unlock()

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)

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

    enum TileabilityResult {
        case tileable
        case nonStandard
        case unavailable
    }

    /// Fast O(1) check whether `windowID` was already verified as a standard tileable window.
    func isKnownTileable(windowID: WindowID, pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tileableCache.contains(windowID) && elementCache[windowID]?.pid == pid
    }

    /// Check if a window is a standard resizable window (skipping sheets, popovers, system dialogs),
    /// distinguishing definitive non-standard windows from transient AX timeouts/unavailability.
    /// Runs synchronously on the caller's queue; call from a PID queue or background queue.
    func checkTileability(windowID: WindowID, pid: pid_t, timeout: Float = AXWindowBridge.axTimeout) -> TileabilityResult {
        guard let el = resolveElement(windowID: windowID, pid: pid, timeout: timeout) else {
            return .unavailable
        }
        AXUIElementSetMessagingTimeout(el, timeout)

        var roleObj: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleObj) == .success,
           let role = roleObj as? String,
           role != (kAXWindowRole as String) {
            return .nonStandard
        }

        var subroleObj: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleObj) == .success,
           let subrole = subroleObj as? String,
           subrole != (kAXStandardWindowSubrole as String) {
            return .nonStandard
        }

        var resizable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &resizable) == .success,
           !resizable.boolValue {
            return .nonStandard
        }

        lock.lock()
        tileableCache.insert(windowID)
        lock.unlock()
        return .tileable
    }

    /// Asynchronously verify whether `(windowID, pid)` is a standard resizable window off the main thread.
    func checkTileabilityAsync(
        windowID: WindowID,
        pid: pid_t,
        timeout: Float = AXWindowBridge.axTimeout,
        completion: @escaping @MainActor (TileabilityResult) -> Void
    ) {
        if isKnownTileable(windowID: windowID, pid: pid) {
            DispatchQueue.main.async {
                completion(.tileable)
            }
            return
        }
        queue(for: pid).async { [weak self] in
            guard let self else { return }
            let result = self.checkTileability(windowID: windowID, pid: pid, timeout: timeout)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Asynchronously verify tileability for a batch of windows across their per-PID queues
    /// (zero main-thread AX IPC; a slow app cannot stall checks for other apps).
    func checkTileabilityBatchAsync(
        _ targets: [(windowID: WindowID, pid: pid_t)],
        timeout: Float = 0.6,
        completion: @escaping @MainActor ([WindowID: TileabilityResult]) -> Void
    ) {
        guard !targets.isEmpty else {
            DispatchQueue.main.async { completion([:]) }
            return
        }
        var byPID: [pid_t: [WindowID]] = [:]
        for target in targets {
            byPID[target.pid, default: []].append(target.windowID)
        }

        let resultsLock = NSLock()
        var results: [WindowID: TileabilityResult] = [:]
        let group = DispatchGroup()

        for (pid, wids) in byPID {
            group.enter()
            queue(for: pid).async { [weak self] in
                defer { group.leave() }
                guard let self else { return }
                var local: [(WindowID, TileabilityResult)] = []
                for wid in wids {
                    let res = self.checkTileability(windowID: wid, pid: pid, timeout: timeout)
                    local.append((wid, res))
                }
                resultsLock.lock()
                for (wid, res) in local {
                    results[wid] = res
                }
                resultsLock.unlock()
            }
        }

        group.notify(queue: .main) {
            resultsLock.lock()
            let snapshot = results
            resultsLock.unlock()
            MainActor.assumeIsolated {
                completion(snapshot)
            }
        }
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
        completion: (@MainActor () -> Void)? = nil
    ) {
        var grouped: [pid_t: [(WindowID, CGRect)]] = [:]
        for (wid, frame) in frames {
            guard let pid = pid(for: wid) else { continue }
            grouped[pid, default: []].append((wid, frame))
        }

        guard !grouped.isEmpty else {
            if let completion {
                DispatchQueue.main.async { completion() }
            }
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
            group.notify(queue: .main) {
                MainActor.assumeIsolated {
                    completion()
                }
            }
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
