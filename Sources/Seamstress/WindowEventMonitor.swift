import ApplicationServices
import Cocoa
import Foundation
import SeamstressCore

/// Observes lifecycle events ONLY for PIDs that currently own tiled windows (close, minimize,
/// app hide, app quit), plus a lightweight CGWindowList sanity sweep for fullscreen/closed windows.
final class WindowEventMonitor {
    var onWindowBecameUnavailable: ((WindowID) -> Void)?
    var onApplicationUnavailable: ((pid_t) -> Void)?
    var onSanitySweep: (() -> Void)?

    private var pidObservers: [pid_t: AXObserver] = [:]
    private var wsObservers: [NSObjectProtocol] = []
    private var sanityTimer: Timer?

    func start() {
        guard wsObservers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter

        wsObservers.append(ws.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.onApplicationUnavailable?(app.processIdentifier)
            }
        })

        wsObservers.append(ws.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.removeObserver(for: app.processIdentifier)
                self?.onApplicationUnavailable?(app.processIdentifier)
            }
        })

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.onSanitySweep?()
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        sanityTimer = timer
    }

    func stop() {
        sanityTimer?.invalidate()
        sanityTimer = nil

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

    fileprivate func handleAXNotification(element: AXUIElement, notification: CFString) {
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(element, &wid) == .success, wid != 0 {
            onWindowBecameUnavailable?(wid)
        } else {
            // Destroyed elements sometimes lose their CGWindowID before the callback arrives;
            // run an immediate CGWindowList sanity sweep to clean up any vanished window.
            onSanitySweep?()
        }
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
    monitor.handleAXNotification(element: element, notification: notification)
}
