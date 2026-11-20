import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation
import SeamstressCore

/// Dedicated high-QoS `CGEventTap` for mouse and Option-key observation.
///
/// Performance design:
/// - Runs on a dedicated `.userInteractive` thread so a busy main thread never stalls cursor input.
/// - `mouseMoved` does a pure O(N) in-memory rect check on the tap thread against visible seams
///   (typically 0–10 rects). Moving the mouse anywhere outside a seam triggers zero main-thread hops.
/// - Only swallows mouse events when clicking/dragging an unoccluded Seamstress seam; normal
///   window drags (titlebar drag and `⌥⌘` drag-anywhere) pass straight through to macOS untouched.
final class InputEventTap {
    var onHoverCandidateChanged: ((_ seam: VisibleSeam?, _ point: CGPoint) -> Void)?
    /// Synchronous fast Z-order check used on `leftMouseDown` if the user clicks a seam
    /// before the async hover check has landed on main.
    var isSeamUnoccludedSync: ((_ seam: VisibleSeam, _ point: CGPoint) -> Bool)?
    var onSeamDragBegin: ((_ seam: VisibleSeam, _ point: CGPoint) -> Void)?
    var onSeamDragMove: ((_ seam: VisibleSeam, _ point: CGPoint) -> Void)?
    var onSeamDragEnd: ((_ seam: VisibleSeam, _ point: CGPoint) -> Void)?
    var onSeamDoubleClick: ((_ seam: VisibleSeam) -> Void)?

    var onWindowMouseDown: ((_ point: CGPoint, _ optionDown: Bool) -> Void)?
    var onWindowMouseDragged: ((_ point: CGPoint, _ optionDown: Bool) -> Void)?
    var onWindowMouseUp: ((_ point: CGPoint, _ optionDown: Bool) -> Void)?
    var onOptionFlagChangedDuringDrag: ((_ optionDown: Bool, _ point: CGPoint) -> Void)?

    private let lock = NSLock()
    private var visibleSeams: [VisibleSeam] = []
    private var unoccludedSeam: VisibleSeam?
    private var lastHoverSeamID: NodeID?
    private var lastHoverNotifyPoint: CGPoint = .zero

    private var activeSeamDrag: VisibleSeam?
    private var swallowingDoubleClickUp = false
    private var isLeftMouseDown = false
    private var lastOptionDown = false

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
        if let current = unoccludedSeam, !seams.contains(where: { $0.splitID == current.splitID && $0.spaceKey == current.spaceKey }) {
            unoccludedSeam = nil
            lastHoverSeamID = nil
        }
        lock.unlock()
    }

    /// Called from main thread after checking Z-order occlusion for a hovered seam candidate.
    func setUnoccludedHoverSeam(_ seam: VisibleSeam?) {
        lock.lock()
        unoccludedSeam = seam
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
            (1 << CGEventType.flagsChanged.rawValue)

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
        isLeftMouseDown = false
        unoccludedSeam = nil
        lastHoverSeamID = nil
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
        let point = event.location
        let optionDown = event.flags.contains(.maskAlternate)

        switch type {
        case .mouseMoved:
            lock.lock()
            let dragging = activeSeamDrag != nil || isLeftMouseDown
            let seams = visibleSeams
            let prevID = lastHoverSeamID
            let prevPoint = lastHoverNotifyPoint
            lock.unlock()

            guard !dragging else { return event }

            let hit = SeamGeometry.hitTest(point: point, seams: seams)
            let hitID = hit?.splitID

            // Notify main thread only when entering/leaving/switching seams, or after moving
            // >= 16pt along the same seam (handles sliding past an occluding floating window).
            let movedAlongSeam = hit != nil && hypot(point.x - prevPoint.x, point.y - prevPoint.y) >= 16
            if hitID != prevID || movedAlongSeam {
                lock.lock()
                lastHoverSeamID = hitID
                lastHoverNotifyPoint = point
                if hit == nil { unoccludedSeam = nil }
                lock.unlock()

                DispatchQueue.main.async { [weak self] in
                    self?.onHoverCandidateChanged?(hit, point)
                }
            }
            return event

        case .leftMouseDown:
            let clickState = event.getIntegerValueField(.mouseEventClickState)

            lock.lock()
            let candidate = unoccludedSeam
            let seams = visibleSeams
            lock.unlock()

            // Fast-click fallback: if the cursor moved onto a seam and clicked before
            // the main-thread hover check finished, verify occlusion synchronously (~0.1ms).
            var grabbedSeam: VisibleSeam?
            if let existing = candidate, existing.hitRect.contains(point) {
                grabbedSeam = existing
            } else if let directHit = SeamGeometry.hitTest(point: point, seams: seams),
                      isSeamUnoccludedSync?(directHit, point) == true {
                grabbedSeam = directHit
            }

            lock.lock()
            if let seam = grabbedSeam {
                unoccludedSeam = seam
                isLeftMouseDown = true
                if clickState >= 2 {
                    swallowingDoubleClickUp = true
                    activeSeamDrag = nil
                    lock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.onSeamDoubleClick?(seam)
                    }
                    return nil
                } else {
                    swallowingDoubleClickUp = false
                    activeSeamDrag = seam
                    lock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.onSeamDragBegin?(seam, point)
                    }
                    return nil
                }
            }
            isLeftMouseDown = true
            lastOptionDown = optionDown
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onWindowMouseDown?(point, optionDown)
            }
            return event

        case .leftMouseDragged:
            lock.lock()
            if swallowingDoubleClickUp {
                lock.unlock()
                return nil
            }
            if let seam = activeSeamDrag {
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onSeamDragMove?(seam, point)
                }
                return nil
            }
            lastOptionDown = optionDown
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onWindowMouseDragged?(point, optionDown)
            }
            return event

        case .leftMouseUp:
            lock.lock()
            isLeftMouseDown = false
            if swallowingDoubleClickUp {
                swallowingDoubleClickUp = false
                lock.unlock()
                return nil
            }
            if let seam = activeSeamDrag {
                activeSeamDrag = nil
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.onSeamDragEnd?(seam, point)
                }
                return nil
            }
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onWindowMouseUp?(point, optionDown)
            }
            return event

        case .flagsChanged:
            lock.lock()
            let shouldNotify = isLeftMouseDown && activeSeamDrag == nil && optionDown != lastOptionDown
            if shouldNotify {
                lastOptionDown = optionDown
            }
            lock.unlock()

            if shouldNotify {
                DispatchQueue.main.async { [weak self] in
                    self?.onOptionFlagChangedDuringDrag?(optionDown, point)
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
