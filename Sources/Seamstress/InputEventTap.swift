import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation
import SeamstressCore

/// Dedicated high-QoS `CGEventTap` for mouse and snap-modifier (`⌥` or `⌃⌘`) observation.
///
/// Performance design:
/// - Runs on a dedicated `.userInteractive` thread so a busy main thread never stalls cursor input.
/// - `mouseMoved` does a pure O(N) in-memory rect check on the tap thread against visible seams
///   (typically 0–10 rects). Moving the mouse anywhere outside a seam triggers zero main-thread hops.
/// - Only swallows mouse events when clicking/dragging an unoccluded Seamstress seam or `┼`
///   intersection; normal window drags (titlebar drag and `⌃⌘` drag-anywhere) pass straight through.
final class InputEventTap {
    /// Returns true when the snap/split modifier is active: either `⌥` (Option) or `⌃⌘`
    /// (Control+Command, used by macOS's `NSWindowShouldDragOnGesture` drag-anywhere gesture).
    static func isSnapModifierActive(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate) || isGestureDragModifierActive(flags)
    }

    /// Returns true when `⌃⌘` (Control+Command) is held for macOS drag-anywhere window moves.
    static func isGestureDragModifierActive(_ flags: CGEventFlags) -> Bool {
        flags.contains([.maskControl, .maskCommand])
    }

    var onHoverCandidateChanged: ((_ hit: SeamHit?, _ point: CGPoint) -> Void)?
    var onHoverCursorReassert: (() -> Void)?
    /// Synchronous fast Z-order check used on `leftMouseDown` if the user clicks a seam
    /// before the async hover check has landed on main.
    var isSeamHitUnoccludedSync: ((_ hit: SeamHit, _ point: CGPoint) -> Bool)?
    /// Synchronous WindowServer hit-test used on Option+`leftMouseDown` to avoid macOS hiding
    /// the previously focused app when clicking an unfocused tiled window (or clicking away from one).
    var topWindowAtPointSync: ((_ point: CGPoint) -> (windowID: WindowID, ownerPID: pid_t)?)?
    var onSeamDragBegin: ((_ hit: SeamHit, _ point: CGPoint) -> Void)?
    var onSeamDragMove: ((_ hit: SeamHit, _ point: CGPoint, _ shiftDown: Bool) -> Void)?
    var onSeamDragEnd: ((_ hit: SeamHit, _ point: CGPoint) -> Void)?
    var onSeamDragCancel: (() -> Void)?
    var onSeamShiftChangedDuringDrag: ((_ shiftDown: Bool, _ point: CGPoint) -> Void)?
    var onSeamDoubleClick: ((_ hit: SeamHit) -> Void)?

    var onWindowMouseDown: ((_ point: CGPoint, _ snapModifierDown: Bool, _ isGestureDrag: Bool) -> Void)?
    var onWindowMouseDragged: ((_ point: CGPoint, _ snapModifierDown: Bool) -> Void)?
    var onWindowMouseUp: ((_ point: CGPoint, _ snapModifierDown: Bool) -> Void)?
    var onWindowDragCancel: (() -> Void)?
    var onSnapModifierChangedDuringDrag: ((_ snapModifierDown: Bool, _ point: CGPoint) -> Void)?

    private let lock = NSLock()
    private var visibleSeams: [VisibleSeam] = []
    private var tiledWindowIDs: Set<WindowID> = []
    private var tiledPIDs: Set<pid_t> = []
    private var unoccludedHit: SeamHit?
    private var lastHoverIdentity: String?
    private var lastHoverNotifyPoint: CGPoint = .zero
    private var lastCursorReassertUptime: TimeInterval = 0

    private static let syntheticCancelTag: Int64 = 0x5345_414D_4341_4E43

    private var activeSeamDrag: SeamHit?
    private var swallowingDoubleClickUp = false
    private var swallowingCancelledSeamDrag = false
    private var swallowingCancelledWindowDrag = false
    private var isLeftMouseDown = false
    private var lastSnapModifierDown = false
    private var lastShiftDownDuringSeamDrag = false
    private var hasActiveWindowMove = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var healthTimer: Timer?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventTap != nil
    }

    func updateVisibleSeams(_ seams: [VisibleSeam]) {
        lock.lock()
        visibleSeams = seams
        if let current = unoccludedHit {
            let valid = current.allSeams.allSatisfy { target in
                seams.contains(where: { $0.splitID == target.splitID && $0.spaceKey == target.spaceKey })
            }
            if !valid {
                unoccludedHit = nil
                lastHoverIdentity = nil
            }
        }
        lock.unlock()
    }

    /// Called from main thread whenever the set of tiled windows or owning PIDs changes.
    func updateTiledState(windowIDs: Set<WindowID>, pids: Set<pid_t>) {
        lock.lock()
        tiledWindowIDs = windowIDs
        tiledPIDs = pids
        lock.unlock()
    }

    /// Called from main thread after checking Z-order occlusion for a hovered seam candidate.
    func setUnoccludedHoverHit(_ hit: SeamHit?) {
        lock.lock()
        unoccludedHit = hit
        lock.unlock()
    }

    /// Called from main thread to inform the tap whether a confirmed window drag is in progress
    /// so pressing Escape while holding the mouse button down can undo it immediately.
    func setHasActiveWindowMove(_ active: Bool) {
        lock.lock()
        hasActiveWindowMove = active
        lock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        let alreadyRunning = eventTap != nil
        lock.unlock()
        guard !alreadyRunning else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputEventTapCallback,
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        lock.lock()
        eventTap = tap
        runLoopSource = source
        lock.unlock()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let rl = CFRunLoopGetCurrent()
            self?.lock.lock()
            self?.tapRunLoop = rl
            self?.lock.unlock()

            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Seamstress.EventTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        ready.wait()

        startHealthCheck()
        return true
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil

        lock.lock()
        let tap = eventTap
        let rl = tapRunLoop
        let source = runLoopSource
        eventTap = nil
        tapRunLoop = nil
        runLoopSource = nil
        activeSeamDrag = nil
        swallowingDoubleClickUp = false
        swallowingCancelledSeamDrag = false
        swallowingCancelledWindowDrag = false
        isLeftMouseDown = false
        lastSnapModifierDown = false
        lastShiftDownDuringSeamDrag = false
        hasActiveWindowMove = false
        unoccludedHit = nil
        lastHoverIdentity = nil
        lastCursorReassertUptime = 0
        tiledWindowIDs = []
        tiledPIDs = []
        lock.unlock()

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let rl {
            if let source { CFRunLoopRemoveSource(rl, source, .commonModes) }
            CFRunLoopStop(rl)
        }
        tapThread = nil
    }

    private func startHealthCheck() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let tap = self.eventTap
            self.lock.unlock()
            if let tap, !CGEvent.tapIsEnabled(tap: tap) {
                SeamstressLog.lifecycle.notice("Event tap was disabled by macOS — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    fileprivate func tapHandle() -> CFMachPort? {
        lock.lock()
        defer { lock.unlock() }
        return eventTap
    }

    /// Runs on the dedicated EventTap thread. Must return in microseconds.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticCancelTag {
            return event
        }

        // Fast path for normal typing: pass non-Escape keyDown events straight through
        // without acquiring the lock or hopping to main.
        if type == .keyDown {
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
                return event
            }
            lock.lock()
            if activeSeamDrag != nil {
                activeSeamDrag = nil
                lastShiftDownDuringSeamDrag = false
                swallowingCancelledSeamDrag = true
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onSeamDragCancel?()
                }
                return nil
            }
            if isLeftMouseDown && hasActiveWindowMove {
                hasActiveWindowMove = false
                swallowingCancelledWindowDrag = true
                lock.unlock()

                // Terminate macOS's native window-drag loop immediately so the window
                // snaps back to its pre-drag frame while the user still holds the mouse button.
                let cursorPoint = event.location
                if let syntheticUp = CGEvent(
                    mouseEventSource: nil,
                    mouseType: .leftMouseUp,
                    mouseCursorPosition: cursorPoint,
                    mouseButton: .left
                ) {
                    syntheticUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticCancelTag)
                    syntheticUp.post(tap: .cgSessionEventTap)
                }

                DispatchQueue.main.async { [weak self] in
                    self?.onWindowDragCancel?()
                }
                return nil
            }
            lock.unlock()
            return event
        }

        let point = event.location
        let snapModifierDown = Self.isSnapModifierActive(event.flags)

        switch type {
        case .mouseMoved:
            lock.lock()
            let dragging = activeSeamDrag != nil || isLeftMouseDown
            let seams = visibleSeams
            let prevID = lastHoverIdentity
            let prevPoint = lastHoverNotifyPoint
            lock.unlock()

            guard !dragging else { return event }

            let hit = SeamGeometry.hitTestTarget(point: point, seams: seams)
            let hitID = hit?.identityKey

            // Notify main thread only when entering/leaving/switching seams, or after moving
            // >= 16pt along the same seam (handles sliding past an occluding floating window).
            let movedAlongSeam = hit != nil && hypot(point.x - prevPoint.x, point.y - prevPoint.y) >= 16
            if hitID != prevID || movedAlongSeam {
                let now = ProcessInfo.processInfo.systemUptime
                lock.lock()
                lastHoverIdentity = hitID
                lastHoverNotifyPoint = point
                lastCursorReassertUptime = now
                if hit == nil { unoccludedHit = nil }
                lock.unlock()

                DispatchQueue.main.async { [weak self] in
                    self?.onHoverCandidateChanged?(hit, point)
                }
            } else if hit != nil {
                // Throttled cursor re-assertion (~80ms) while hovering the same seam so
                // Chromium / Electron / editors cannot permanently steal the resize cursor.
                let now = ProcessInfo.processInfo.systemUptime
                lock.lock()
                let shouldReassert = unoccludedHit != nil && (now - lastCursorReassertUptime) >= 0.08
                if shouldReassert {
                    lastCursorReassertUptime = now
                }
                lock.unlock()

                if shouldReassert {
                    DispatchQueue.main.async { [weak self] in
                        self?.onHoverCursorReassert?()
                    }
                }
            }
            return event

        case .leftMouseDown:
            let clickState = event.getIntegerValueField(.mouseEventClickState)

            lock.lock()
            let candidate = unoccludedHit
            let seams = visibleSeams
            lock.unlock()

            // Fast-click fallback: if the cursor moved onto a seam and clicked before
            // the main-thread hover check finished, verify occlusion synchronously (~0.1ms).
            var grabbed: SeamHit?
            if let existing = candidate, existing.contains(point) {
                grabbed = existing
            } else if let directHit = SeamGeometry.hitTestTarget(point: point, seams: seams),
                      isSeamHitUnoccludedSync?(directHit, point) == true {
                grabbed = directHit
            }

            let shiftDown = event.flags.contains(.maskShift)

            lock.lock()
            swallowingCancelledSeamDrag = false
            swallowingCancelledWindowDrag = false
            if let hit = grabbed {
                unoccludedHit = hit
                isLeftMouseDown = true
                if clickState >= 2 {
                    swallowingDoubleClickUp = true
                    activeSeamDrag = nil
                    lastShiftDownDuringSeamDrag = false
                    lock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.onSeamDoubleClick?(hit)
                    }
                    return nil
                } else {
                    swallowingDoubleClickUp = false
                    activeSeamDrag = hit
                    lastShiftDownDuringSeamDrag = shiftDown
                    lock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.onSeamDragBegin?(hit, point)
                    }
                    return nil
                }
            }
            isLeftMouseDown = true
            lastSnapModifierDown = snapModifierDown
            let currentTiledWindowIDs = tiledWindowIDs
            let currentTiledPIDs = tiledPIDs
            lock.unlock()

            let originalFlags = event.flags
            let isGestureDrag = Self.isGestureDragModifierActive(originalFlags)

            // Prevent macOS's native "Option-click another app to hide the previous app"
            // shortcut from hiding a focused window and evicting it from the layout.
            if originalFlags.contains(.maskAlternate),
               !originalFlags.contains(.maskCommand),
               !originalFlags.contains(.maskControl),
               (!currentTiledWindowIDs.isEmpty || !currentTiledPIDs.isEmpty),
               let top = topWindowAtPointSync?(point),
               let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               OptionClickPolicy.shouldStripOptionOnMouseDown(
                   flags: originalFlags,
                   clickedWindowID: top.windowID,
                   clickedOwnerPID: top.ownerPID,
                   frontmostPID: frontmostPID,
                   tiledWindowIDs: currentTiledWindowIDs,
                   tiledPIDs: currentTiledPIDs
               ) {
                event.flags = OptionClickPolicy.strippingOption(from: originalFlags)
            }

            DispatchQueue.main.async { [weak self] in
                self?.onWindowMouseDown?(point, snapModifierDown, isGestureDrag)
            }
            return event

        case .leftMouseDragged:
            let shiftDown = event.flags.contains(.maskShift)
            lock.lock()
            if swallowingDoubleClickUp || swallowingCancelledSeamDrag || swallowingCancelledWindowDrag {
                lock.unlock()
                return nil
            }
            if let hit = activeSeamDrag {
                lastShiftDownDuringSeamDrag = shiftDown
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onSeamDragMove?(hit, point, shiftDown)
                }
                return nil
            }
            lastSnapModifierDown = snapModifierDown
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onWindowMouseDragged?(point, snapModifierDown)
            }
            return event

        case .leftMouseUp:
            lock.lock()
            isLeftMouseDown = false
            hasActiveWindowMove = false
            if swallowingDoubleClickUp || swallowingCancelledSeamDrag || swallowingCancelledWindowDrag {
                swallowingDoubleClickUp = false
                swallowingCancelledSeamDrag = false
                swallowingCancelledWindowDrag = false
                lock.unlock()
                return nil
            }
            if let hit = activeSeamDrag {
                activeSeamDrag = nil
                lastShiftDownDuringSeamDrag = false
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onSeamDragEnd?(hit, point)
                }
                return nil
            }
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onWindowMouseUp?(point, snapModifierDown)
            }
            return event

        case .flagsChanged:
            let shiftDown = event.flags.contains(.maskShift)
            lock.lock()
            let notifySeamShift = activeSeamDrag != nil && shiftDown != lastShiftDownDuringSeamDrag
            if notifySeamShift {
                lastShiftDownDuringSeamDrag = shiftDown
            }
            let notifyWindowSnap = !notifySeamShift && isLeftMouseDown && activeSeamDrag == nil && !swallowingCancelledSeamDrag && !swallowingCancelledWindowDrag && snapModifierDown != lastSnapModifierDown
            if notifyWindowSnap {
                lastSnapModifierDown = snapModifierDown
            }
            lock.unlock()

            if notifySeamShift {
                DispatchQueue.main.async { [weak self] in
                    self?.onSeamShiftChangedDuringDrag?(shiftDown, point)
                }
            } else if notifyWindowSnap {
                DispatchQueue.main.async { [weak self] in
                    self?.onSnapModifierChangedDuringDrag?(snapModifierDown, point)
                }
            }
            return event

        default:
            return event
        }
    }
}

private func inputEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    let tap = Unmanaged<InputEventTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let handle = tap.tapHandle() {
            CGEvent.tapEnable(tap: handle, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    if let passthrough = tap.handle(type: type, event: event) {
        return Unmanaged.passRetained(passthrough)
    }
    return nil
}
