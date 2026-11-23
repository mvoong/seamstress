import ApplicationServices
import Cocoa
import Foundation
import SeamstressCore

/// Observes lifecycle events ONLY for PIDs that currently own tiled windows (close, minimize,
/// app hide, app quit), plus frontmost-app tracking and a lightweight CGWindowList sanity sweep
/// for fullscreen/closed windows.
@MainActor
final class WindowEventMonitor {
    var onWindowBecameUnavailable: ((WindowID) -> Void)?
    var onApplicationUnavailable: ((pid_t) -> Void)?
    var onApplicationTerminated: ((pid_t) -> Void)?
    var onFrontmostApplicationChanged: ((pid_t?) -> Void)?
    var onSanitySweep: (() -> Void)?

    private var pidObservers: [pid_t: AXObserver] = [:]
    private var wsObservers: [NSObjectProtocol] = []
    private var sanityTimer: Timer?
    private var pendingFallbackSweep: DispatchWorkItem?

    func start() {
        guard wsObservers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter

        wsObservers.append(ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                self?.onFrontmostApplicationChanged?(pid)
            }
        })

        wsObservers.append(ws.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else {
                return
            }
            MainActor.assumeIsolated {
                self?.onApplicationUnavailable?(pid)
            }
        })

        wsObservers.append(ws.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else {
                return
            }
            MainActor.assumeIsolated {
                self?.removeObserver(for: pid)
                self?.onApplicationUnavailable?(pid)
                self?.onApplicationTerminated?(pid)
            }
        })

        onFrontmostApplicationChanged?(NSWorkspace.shared.frontmostApplication?.processIdentifier)

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onSanitySweep?()
            }
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        sanityTimer = timer
    }

    func stop() {
        sanityTimer?.invalidate()
        sanityTimer = nil
        pendingFallbackSweep?.cancel()
        pendingFallbackSweep = nil

        let ws = NSWorkspace.shared.notificationCenter
        for obs in wsObservers {
            ws.removeObserver(obs)
        }
        wsObservers.removeAll()

        for pid in Array(pidObservers.keys) {
            removeObserver(for: pid)
        }
    }

    /// Synchronize observed PIDs with the current set of PIDs that own tiled windows.
    func syncObservedPIDs(_ desired: Set<pid_t>) {
        let current = Set(pidObservers.keys)
        for obsolete in current.subtracting(desired) {
            removeObserver(for: obsolete)
        }
        for added in desired.subtracting(current) {
            addObserver(for: added)
        }
    }

    private func addObserver(for pid: pid_t) {
        var observer: AXObserver?
        let err = AXObserverCreate(pid, axObserverCallback, &observer)
        guard err == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(observer, appElement, kAXUIElementDestroyedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXWindowMiniaturizedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        pidObservers[pid] = observer
    }

    private func removeObserver(for pid: pid_t) {
        guard let observer = pidObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func scheduleDebouncedFallbackSweep() {
        guard pendingFallbackSweep == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFallbackSweep = nil
            self.onSanitySweep?()
        }
        pendingFallbackSweep = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    fileprivate func handleAXNotification(element: AXUIElement, notification: CFString) {
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(element, &wid) == .success, wid != 0 {
            onWindowBecameUnavailable?(wid)
            return
        }

        // Application-level `kAXUIElementDestroyedNotification` fires for transient UI elements
        // (menus, tooltips, popovers, Chromium DOM nodes). Skip elements whose role is clearly
        // not a window, and coalesce any remaining fallback sweep so bursts don't spam CGWindowList.
        var roleObj: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleObj) == .success,
           let role = roleObj as? String,
           role != (kAXWindowRole as String) {
            return
        }
        scheduleDebouncedFallbackSweep()
    }
}

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<WindowEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.handleAXNotification(element: element, notification: notification)
    }
}
