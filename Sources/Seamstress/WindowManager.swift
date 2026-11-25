import Cocoa
import CoreGraphics
import Foundation
import SeamstressCore

/// Pre-resolved tile view model for the menu bar minimap (avoids per-render `NSRunningApplication` lookups).
struct MinimapTile: Identifiable, Equatable {
    let id: NodeID
    let windowID: WindowID?
    let frame: CGRect
    let appName: String?
    let appIcon: NSImage?

    var isEmpty: Bool { windowID == nil }
}

/// Top-level coordinator connecting `InputEventTap`, `DisplayObserver`, `SpaceLayoutStore`,
/// `AXWindowBridge`, `WindowEventMonitor`, and the drag/overlay controllers.
@MainActor
final class WindowManager: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var activeMinimapTiles: [MinimapTile] = []
    @Published private(set) var activeDisplayBounds: CGRect = .zero
    @Published private(set) var activeDisplayName: String = ""
    @Published private(set) var canEqualizeCurrentSpace: Bool = false
    @Published private(set) var tiledWindowCount: Int = 0

    private let displayObserver = DisplayObserver()
    private let store = SpaceLayoutStore()
    private let axBridge = AXWindowBridge()
    private let eventMonitor = WindowEventMonitor()
    private let inputTap = InputEventTap()
    private let dropOverlay = DropPreviewOverlay()
    private let seamOverlay = SeamHighlightOverlay()
    private let seamDragController: SeamDragController
    private let windowDragController: WindowDragController

    private struct PendingLaunchRestore {
        let appKey: AppKey
        let pid: pid_t
        let expectedWindowCount: Int
        let deadline: TimeInterval
        var firstTileableSeenAt: TimeInterval?
        var rejectedWindowIDs: Set<WindowID> = []
        var checkingWindowIDs: Set<WindowID> = []
        var verifiedTileable: [WindowID: LaunchedWindow] = [:]
        var pollWorkItem: DispatchWorkItem?
    }

    private var pendingLaunchRestores: [AppKey: PendingLaunchRestore] = [:]
    private static let launchRestoreTimeout: TimeInterval = 6.0
    private static let launchRestorePollInterval: TimeInterval = 0.15
    private static let launchRestoreMultiWindowSettle: TimeInterval = 0.25

    /// Spaces already probed for existing tiled layouts since launch (so manually cleared
    /// Spaces are never re-adopted on later Space switches).
    private var probedSpaces: Set<SpaceKey> = []
    private var adoptionGeneration: UInt64 = 0
    private var pendingAdoptionRetry: DispatchWorkItem?
    private var adoptionRetryCount: Int = 0
    private var pendingTopologyReapply: DispatchWorkItem?
    /// Suppresses `runSanitySweep()` briefly after wake, unlock, or display topology changes
    /// so transient WindowServer transitions never evict live tiled windows.
    private var sanitySweepSuppressedUntil: TimeInterval = 0
    private static let postWakeSweepGrace: TimeInterval = 2.5

    init() {
        self.seamDragController = SeamDragController(
            store: store,
            displayObserver: displayObserver,
            axBridge: axBridge,
            inputTap: inputTap,
            seamOverlay: seamOverlay
        )
        self.windowDragController = WindowDragController(
            store: store,
            displayObserver: displayObserver,
            axBridge: axBridge,
            inputTap: inputTap,
            dropOverlay: dropOverlay,
            seamOverlay: seamOverlay
        )
        wireCallbacks()
    }

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else { return }

        SkyLightBridge.shared.enableBackgroundCursor()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXWindowBridge.axTimeout)

        let restored = LayoutPersistence.loadSavedFloatingFrames()
        if !restored.isEmpty {
            store.restoreSavedFloatingFrames(restored)
        }

        displayObserver.refresh()
        displayObserver.startObserving()
        eventMonitor.start()

        guard inputTap.start() else {
            SeamstressLog.lifecycle.error("Failed to create CGEventTap")
            displayObserver.stopObserving()
            eventMonitor.stop()
            return
        }

        isRunning = true
        SeamstressLog.lifecycle.notice("Seamstress started")
        adoptExistingLayoutsIfNeeded()
        refreshSeamsAndUI()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        adoptionGeneration &+= 1
        pendingTopologyReapply?.cancel()
        pendingTopologyReapply = nil
        pendingAdoptionRetry?.cancel()
        pendingAdoptionRetry = nil
        adoptionRetryCount = 0
        cancelAllPendingLaunchRestores()

        persistSavedFloatingFrames()
        resetActiveInteractions()
        inputTap.stop()
        eventMonitor.stop()
        displayObserver.stopObserving()
        SeamstressLog.lifecycle.notice("Seamstress stopped")
    }

    /// Refresh menu-bar / standalone window state for the display under the cursor.
    func refreshForMenuPresentation() {
        updateMenuState()
    }

    /// Reset all splits in the active Space on the current display back to 50/50.
    func equalizeCurrentSpaceLayout() {
        guard let display = currentMenuDisplay() else { return }
        guard let frames = store.equalizeSplits(in: display.spaceKey, screenBounds: display.usableFrameCG) else {
            return
        }
        axBridge.applyFrames(frames, crossMonitorSafe: false)
        SeamstressLog.layout.info("Equalized splits for space \(display.spaceKey.description, privacy: .public)")
        refreshSeamsAndUI()
    }

    func focusWindow(_ windowID: WindowID) {
        axBridge.focusWindow(windowID: windowID)
    }

    /// Clear all tiled slots on the display under the mouse (or primary display).
    func resetCurrentSpaceLayout() {
        guard let display = currentMenuDisplay() else { return }
        let space = display.spaceKey
        let wids = store.tree(for: space).allWindowIDs
        for wid in wids {
            _ = store.handleWindowUnavailable(wid)
        }
        SeamstressLog.layout.info("Cleared layout for space \(space.description, privacy: .public) (\(wids.count) windows)")
        refreshSeamsAndUI()
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        let isIdle: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.isRunning && !self.seamDragController.isActive && !self.windowDragController.isActive
        }

        seamDragController.onRefreshSeamsAndUI = { [weak self] in
            self?.refreshSeamsAndUI()
        }
        seamDragController.onRecordDeclaredMinSize = { [weak self] wid in
            self?.recordDeclaredMinSizeIfAvailable(for: wid)
        }
        seamDragController.onScheduleMinSizeLearn = { [weak self] expected, spaceKey in
            self?.scheduleSettledMinSizeLearn(expected: expected, in: spaceKey)
        }

        windowDragController.onRefreshSeamsAndUI = { [weak self] in
            self?.refreshSeamsAndUI()
        }
        windowDragController.onPersistFloatingFrames = { [weak self] in
            self?.persistSavedFloatingFrames()
        }
        windowDragController.onRecordDeclaredMinSize = { [weak self] wid in
            self?.recordDeclaredMinSizeIfAvailable(for: wid)
        }
        windowDragController.onScheduleMinSizeLearn = { [weak self] expected, spaceKey in
            self?.scheduleSettledMinSizeLearn(expected: expected, in: spaceKey)
        }
        windowDragController.onApplyFramesIfActive = { [weak self] spaces, excluding in
            self?.applyFramesIfActive(spaces: spaces, excluding: excluding)
        }
        windowDragController.isIdleForVerification = isIdle

        displayObserver.onDisplaysOrSpacesChanged = { [weak self] topologyChanged in
            guard let self, self.isRunning else { return }
            self.resetActiveInteractions()

            if topologyChanged {
                self.suppressSanitySweepForWakeGrace()
                self.scheduleDebouncedTopologyReapply()
            } else {
                self.adoptExistingLayoutsIfNeeded()
            }
            self.refreshSeamsAndUI()
        }

        displayObserver.onSessionActivityChanged = { [weak self] isActive in
            guard let self, self.isRunning else { return }
            if !isActive {
                self.resetActiveInteractions()
                SeamstressLog.lifecycle.info("Session inactive (sleep/lock) — pausing sanity sweeps")
            } else {
                self.suppressSanitySweepForWakeGrace()
                SeamstressLog.lifecycle.info("Session active (wake/unlock) — resuming after grace window")
            }
        }

        eventMonitor.onWindowBecameUnavailable = { [weak self] wid in
            guard let self, self.isRunning else { return }
            let appKey = self.axBridge.appKey(for: wid)
            let now = ProcessInfo.processInfo.systemUptime
            if let space = self.store.handleWindowUnavailable(wid, appKey: appKey, timestamp: now) {
                SeamstressLog.layout.info("Window \(wid) unavailable — expanding siblings in \(space.description, privacy: .public)")
                self.axBridge.forget(windowID: wid)
                self.applyFramesIfActive(spaces: [space])
                self.refreshSeamsAndUI()
            }
        }

        eventMonitor.onApplicationUnavailable = { [weak self] pid in
            guard let self, self.isRunning else { return }
            var affectedSpaces: Set<SpaceKey> = []
            for wid in self.store.allTiledWindowIDs {
                if self.axBridge.pid(for: wid) == pid {
                    if let space = self.store.handleWindowUnavailable(wid) {
                        affectedSpaces.insert(space)
                    }
                    self.axBridge.forget(windowID: wid)
                }
            }
            if !affectedSpaces.isEmpty {
                SeamstressLog.layout.info("PID \(pid) hid — expanding siblings in \(affectedSpaces.count) space(s)")
                self.applyFramesIfActive(spaces: affectedSpaces)
                self.refreshSeamsAndUI()
            }
        }

        eventMonitor.onApplicationTerminated = { [weak self] pid, appKey in
            self?.handleApplicationTerminated(pid: pid, appKey: appKey)
        }

        eventMonitor.onApplicationLaunched = { [weak self] pid, appKey in
            self?.handleApplicationLaunched(pid: pid, appKey: appKey)
        }

        eventMonitor.onFrontmostApplicationChanged = { [weak self] pid in
            self?.inputTap.updateFrontmostPID(pid)
        }

        eventMonitor.onSanitySweep = { [weak self] in
            self?.runSanitySweep()
        }

        // Capture thread-safe `axBridge` directly for synchronous EventTap-thread queries
        // so the background tap thread never touches `@MainActor` `WindowManager`.
        let bridge = self.axBridge
        inputTap.isSeamHitUnoccludedSync = { hit, point in
            !bridge.isSeamPointOccluded(point, allowedWindowIDs: hit.participatingWindowIDs)
        }
        inputTap.topWindowAtPointSync = { point in
            guard let win = bridge.topWindow(at: point) else { return nil }
            return (win.windowID, win.ownerPID)
        }

        inputTap.onHoverCandidateChanged = { [weak self] hit, point in
            guard let self else { return }
            self.seamDragController.handleHoverCandidate(
                hit,
                at: point,
                isRunning: self.isRunning,
                isWindowDragActive: self.windowDragController.isActive
            )
        }

        inputTap.onHoverCursorReassert = { [weak self] in
            self?.seamDragController.reassertCursor()
        }

        inputTap.onSeamDragBegin = { [weak self] hit, point in
            guard let self else { return }
            self.seamDragController.handleDragBegin(hit, at: point, isRunning: self.isRunning)
        }

        inputTap.onSeamDragMove = { [weak self] _, point, shiftDown in
            self?.seamDragController.handleDragMove(to: point, shiftDown: shiftDown)
        }

        inputTap.onSeamShiftChangedDuringDrag = { [weak self] shiftDown, point in
            self?.seamDragController.handleDragMove(to: point, shiftDown: shiftDown)
        }

        inputTap.onSeamDragEnd = { [weak self] _, point in
            self?.seamDragController.handleDragEnd(at: point)
        }

        inputTap.onSeamDragCancel = { [weak self] in
            self?.seamDragController.handleDragCancel()
        }

        inputTap.onSeamDoubleClick = { [weak self] hit in
            guard let self else { return }
            self.seamDragController.handleDoubleClick(hit, isRunning: self.isRunning)
        }

        inputTap.onWindowMouseDown = { [weak self] point, snapModifierDown, isGestureDrag in
            guard let self else { return }
            self.windowDragController.handleMouseDown(
                at: point,
                snapModifierDown: snapModifierDown,
                isGestureDrag: isGestureDrag,
                isRunning: self.isRunning
            )
        }

        inputTap.onWindowMouseDragged = { [weak self] point, snapModifierDown in
            self?.windowDragController.handleMouseDragged(to: point, snapModifierDown: snapModifierDown)
        }

        inputTap.onWindowMouseUp = { [weak self] point, snapModifierDown in
            self?.windowDragController.handleMouseUp(at: point, snapModifierDown: snapModifierDown)
        }

        inputTap.onWindowDragCancel = { [weak self] in
            self?.windowDragController.handleDragCancel()
        }

        inputTap.onSnapModifierChangedDuringDrag = { [weak self] snapModifierDown, point in
            self?.windowDragController.handleSnapModifierChanged(snapModifierDown: snapModifierDown, point: point)
        }
    }

    private func resetActiveInteractions() {
        windowDragController.reset()
        seamDragController.reset()
    }

    // MARK: - Quit & relaunch layout history

    private func handleApplicationTerminated(pid: pid_t, appKey: AppKey?) {
        defer { axBridge.evictTerminatedPID(pid) }
        guard isRunning else { return }

        let resolvedAppKey = appKey ?? axBridge.appKey(for: pid)
        if let resolvedAppKey, pendingLaunchRestores[resolvedAppKey]?.pid == pid {
            cancelPendingLaunchRestore(for: resolvedAppKey, discardSnapshot: true)
        }

        let remainingWIDs = store.allTiledWindowIDs.filter { axBridge.pid(for: $0) == pid }.sorted()

        if let resolvedAppKey {
            let now = ProcessInfo.processInfo.systemUptime
            let (affectedSpaces, snapshot) = store.recordApplicationQuit(
                appKey: resolvedAppKey,
                remainingWindowIDs: remainingWIDs,
                timestamp: now
            )
            for wid in remainingWIDs {
                axBridge.forget(windowID: wid)
            }
            if let snapshot {
                SeamstressLog.layout.info(
                    "Recorded quit history for \(resolvedAppKey, privacy: .public) across \(snapshot.spaces.count) space(s)"
                )
            }
            if !affectedSpaces.isEmpty {
                SeamstressLog.layout.info("PID \(pid) quit — expanding siblings in \(affectedSpaces.count) space(s)")
                applyFramesIfActive(spaces: affectedSpaces)
                refreshSeamsAndUI()
            }
        } else if !remainingWIDs.isEmpty {
            var affectedSpaces: Set<SpaceKey> = []
            for wid in remainingWIDs {
                if let space = store.handleWindowUnavailable(wid) {
                    affectedSpaces.insert(space)
                }
                axBridge.forget(windowID: wid)
            }
            if !affectedSpaces.isEmpty {
                SeamstressLog.layout.info("PID \(pid) quit — expanding siblings in \(affectedSpaces.count) space(s)")
                applyFramesIfActive(spaces: affectedSpaces)
                refreshSeamsAndUI()
            }
        }
    }

    private func handleApplicationLaunched(pid: pid_t, appKey: AppKey) {
        guard isRunning, !displayObserver.isSessionInactive else { return }

        let activeSpaceKeys = Set(displayObserver.displays.map(\.spaceKey))
        guard let validSnapshot = store.validQuitSnapshot(for: appKey, activeSpaces: activeSpaceKeys) else {
            store.discardQuitSnapshot(for: appKey)
            return
        }

        axBridge.cacheAppKey(appKey, for: pid)
        cancelPendingLaunchRestore(for: appKey, discardSnapshot: false)

        let now = ProcessInfo.processInfo.systemUptime
        pendingLaunchRestores[appKey] = PendingLaunchRestore(
            appKey: appKey,
            pid: pid,
            expectedWindowCount: validSnapshot.totalExpectedWindows,
            deadline: now + Self.launchRestoreTimeout
        )
        pollPendingLaunchRestore(for: appKey)
    }

    private func pollPendingLaunchRestore(for appKey: AppKey) {
        guard isRunning, !displayObserver.isSessionInactive else {
            cancelPendingLaunchRestore(for: appKey, discardSnapshot: true)
            return
        }
        guard var pending = pendingLaunchRestores[appKey] else { return }
        pending.pollWorkItem?.cancel()
        pending.pollWorkItem = nil

        let activeSpaceKeys = Set(displayObserver.displays.map(\.spaceKey))
        guard store.validQuitSnapshot(for: appKey, activeSpaces: activeSpaceKeys) != nil else {
            cancelPendingLaunchRestore(for: appKey, discardSnapshot: true)
            return
        }

        if let app = NSRunningApplication(processIdentifier: pending.pid), app.isTerminated {
            cancelPendingLaunchRestore(for: appKey, discardSnapshot: true)
            return
        }

        if seamDragController.isActive || windowDragController.isActive {
            pendingLaunchRestores[appKey] = pending
            scheduleNextLaunchRestorePoll(for: appKey)
            return
        }

        let onScreenForPID = axBridge.onScreenNormalWindows().filter { snap in
            snap.ownerPID == pending.pid && !store.isTiled(snap.windowID)
        }

        var unverifiedTargets: [(windowID: WindowID, pid: pid_t)] = []
        var snapByID: [WindowID: CGWindowSnapshot] = [:]

        for snap in onScreenForPID {
            let center = CGPoint(x: snap.bounds.midX, y: snap.bounds.midY)
            let display = displayObserver.display(containing: center)
            if let display, display.isNativeFullscreen(snap.bounds) {
                continue
            }
            if pending.rejectedWindowIDs.contains(snap.windowID) {
                continue
            }
            snapByID[snap.windowID] = snap

            if pending.verifiedTileable[snap.windowID] != nil {
                pending.verifiedTileable[snap.windowID] = LaunchedWindow(
                    windowID: snap.windowID,
                    frame: snap.bounds,
                    spaceKey: display?.spaceKey
                )
            } else if !pending.checkingWindowIDs.contains(snap.windowID) {
                pending.checkingWindowIDs.insert(snap.windowID)
                unverifiedTargets.append((windowID: snap.windowID, pid: pending.pid))
            }
        }

        // Drop any previously verified window that already vanished before commit.
        for wid in Array(pending.verifiedTileable.keys) where snapByID[wid] == nil {
            pending.verifiedTileable.removeValue(forKey: wid)
        }

        pendingLaunchRestores[appKey] = pending

        if !unverifiedTargets.isEmpty {
            let launchedPID = pending.pid
            axBridge.checkTileabilityBatchAsync(unverifiedTargets, timeout: 0.4) { [weak self] results in
                guard let self, self.isRunning,
                      var current = self.pendingLaunchRestores[appKey],
                      current.pid == launchedPID else {
                    return
                }
                let checkTime = ProcessInfo.processInfo.systemUptime
                for target in unverifiedTargets {
                    current.checkingWindowIDs.remove(target.windowID)
                    switch results[target.windowID] ?? .unavailable {
                    case .tileable:
                        if let snap = snapByID[target.windowID] {
                            let center = CGPoint(x: snap.bounds.midX, y: snap.bounds.midY)
                            let spaceKey = self.displayObserver.display(containing: center)?.spaceKey
                            current.verifiedTileable[target.windowID] = LaunchedWindow(
                                windowID: target.windowID,
                                frame: snap.bounds,
                                spaceKey: spaceKey
                            )
                            if current.firstTileableSeenAt == nil {
                                current.firstTileableSeenAt = checkTime
                            }
                        }
                    case .nonStandard:
                        current.rejectedWindowIDs.insert(target.windowID)
                    case .unavailable:
                        break
                    }
                }
                self.pendingLaunchRestores[appKey] = current
                self.evaluatePendingLaunchRestore(for: appKey)
            }
        } else {
            evaluatePendingLaunchRestore(for: appKey)
        }
    }

    private func evaluatePendingLaunchRestore(for appKey: AppKey) {
        guard let pending = pendingLaunchRestores[appKey] else { return }
        let now = ProcessInfo.processInfo.systemUptime

        let readyToCommit: Bool
        if pending.verifiedTileable.count >= pending.expectedWindowCount {
            readyToCommit = true
        } else if !pending.verifiedTileable.isEmpty,
                  let firstSeen = pending.firstTileableSeenAt,
                  (now - firstSeen >= Self.launchRestoreMultiWindowSettle || now >= pending.deadline) {
            readyToCommit = true
        } else {
            readyToCommit = false
        }

        if readyToCommit {
            commitPendingLaunchRestore(for: appKey)
        } else if now >= pending.deadline && pending.checkingWindowIDs.isEmpty {
            cancelPendingLaunchRestore(for: appKey, discardSnapshot: true)
        } else {
            scheduleNextLaunchRestorePoll(for: appKey)
        }
    }

    private func scheduleNextLaunchRestorePoll(for appKey: AppKey) {
        guard var pending = pendingLaunchRestores[appKey] else { return }
        pending.pollWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pollPendingLaunchRestore(for: appKey)
        }
        pending.pollWorkItem = work
        pendingLaunchRestores[appKey] = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchRestorePollInterval, execute: work)
    }

    private func commitPendingLaunchRestore(for appKey: AppKey) {
        guard let pending = pendingLaunchRestores.removeValue(forKey: appKey) else { return }
        pending.pollWorkItem?.cancel()

        guard isRunning,
              !displayObserver.isSessionInactive,
              !seamDragController.isActive,
              !windowDragController.isActive else {
            store.discardQuitSnapshot(for: appKey)
            return
        }

        let activeSpaceKeys = Set(displayObserver.displays.map(\.spaceKey))
        let launched = Array(pending.verifiedTileable.values)
        guard let commit = store.restoreQuitApplication(
            appKey: appKey,
            launchedWindows: launched,
            activeSpaces: activeSpaceKeys,
            boundsForSpace: { [weak self] spaceKey in
                self?.displayObserver.usableBounds(for: spaceKey)
            }
        ) else {
            return
        }

        for win in launched where store.isTiled(win.windowID) {
            recordDeclaredMinSizeIfAvailable(for: win.windowID)
        }

        SeamstressLog.layout.notice(
            "Restored quit layout for \(appKey, privacy: .public) across \(commit.affectedSpaces.count) space(s)"
        )

        let expectedFrames = commit.framesToApply
        let affectedSpaces = commit.affectedSpaces
        axBridge.applyFrames(expectedFrames, crossMonitorSafe: true) { [weak self] in
            guard let self else { return }
            self.schedulePostRestoreDriftCorrection(expected: expectedFrames, after: 0.08)
            self.schedulePostRestoreDriftCorrection(expected: expectedFrames, after: 0.25)
            for space in affectedSpaces {
                let spaceFrames = expectedFrames.filter { self.store.spaceKey(for: $0.key) == space }
                if !spaceFrames.isEmpty {
                    self.scheduleSettledMinSizeLearn(expected: spaceFrames, in: space)
                }
            }
        }

        persistSavedFloatingFrames()
        refreshSeamsAndUI()
    }

    private func schedulePostRestoreDriftCorrection(expected: [WindowID: CGRect], after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning,
                  !self.seamDragController.isActive,
                  !self.windowDragController.isActive else {
                return
            }
            var drifted: [WindowID: CGRect] = [:]
            for (wid, target) in expected where self.store.isTiled(wid) {
                if let actual = self.axBridge.windowBounds(windowID: wid),
                   actual.manhattanDistance(to: target) > 3 {
                    drifted[wid] = target
                }
            }
            if !drifted.isEmpty {
                self.axBridge.applyFrames(drifted, crossMonitorSafe: true)
            }
        }
    }

    private func cancelPendingLaunchRestore(for appKey: AppKey, discardSnapshot: Bool) {
        if let pending = pendingLaunchRestores.removeValue(forKey: appKey) {
            pending.pollWorkItem?.cancel()
        }
        if discardSnapshot {
            store.discardQuitSnapshot(for: appKey)
        }
    }

    private func cancelAllPendingLaunchRestores() {
        for (_, pending) in pendingLaunchRestores {
            pending.pollWorkItem?.cancel()
        }
        pendingLaunchRestores.removeAll()
    }

    // MARK: - Minimum size learning

    private func recordDeclaredMinSizeIfAvailable(for windowID: WindowID) {
        if let declared = SkyLightBridge.shared.declaredMinimumSize(for: windowID) {
            store.recordDeclaredMinimumSize(declared, for: windowID)
        }
        if let liveBounds = axBridge.windowBounds(windowID: windowID) {
            store.reconcileObservedSize(liveBounds.size, for: windowID)
        }
    }

    /// After apps settle (240ms post-release, past drift correction), reconcile observed sizes
    /// and confirm any persistent minimum-size overflow with a second readback (160ms later)
    /// so transient resize lag in Catalyst/Electron apps can never poison clamping.
    private func scheduleSettledMinSizeLearn(expected: [WindowID: CGRect], in spaceKey: SpaceKey) {
        let initialRevision = store.revision(for: spaceKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, self.isRunning,
                  !self.seamDragController.isActive,
                  !self.windowDragController.isActive,
                  self.store.revision(for: spaceKey) == initialRevision else {
                return
            }
            self.sampleSettledMinimumSizes(
                expected: expected,
                in: spaceKey,
                expectedRevision: initialRevision
            )
        }
    }

    private func sampleSettledMinimumSizes(
        expected: [WindowID: CGRect],
        in spaceKey: SpaceKey,
        expectedRevision: UInt64
    ) {
        var candidates: [WindowID: (target: CGRect, firstSample: CGSize)] = [:]
        for (wid, target) in expected {
            guard store.spaceKey(for: wid) == spaceKey,
                  let actual = axBridge.windowBounds(windowID: wid) else {
                continue
            }
            store.reconcileObservedSize(actual.size, for: wid)
            if actual.width > target.width + 6 || actual.height > target.height + 6 {
                candidates[wid] = (target: target, firstSample: actual.size)
            }
        }
        guard !candidates.isEmpty else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self, self.isRunning,
                  !self.seamDragController.isActive,
                  !self.windowDragController.isActive,
                  self.store.revision(for: spaceKey) == expectedRevision else {
                return
            }
            self.confirmSettledMinimumSizes(candidates: candidates, in: spaceKey)
        }
    }

    private func confirmSettledMinimumSizes(
        candidates: [WindowID: (target: CGRect, firstSample: CGSize)],
        in spaceKey: SpaceKey
    ) {
        var learnedAny = false
        for (wid, entry) in candidates {
            guard store.spaceKey(for: wid) == spaceKey,
                  let actual = axBridge.windowBounds(windowID: wid) else {
                continue
            }
            store.reconcileObservedSize(actual.size, for: wid)
            let minW: CGFloat = actual.width > entry.target.width + 6
                ? min(entry.firstSample.width, actual.width)
                : 0
            let minH: CGFloat = actual.height > entry.target.height + 6
                ? min(entry.firstSample.height, actual.height)
                : 0
            if minW > 0 || minH > 0 {
                store.recordMinimumSize(CGSize(width: minW, height: minH), for: wid)
                learnedAny = true
                SeamstressLog.layout.info("Learned settled min size for window \(wid): \(Int(minW))x\(Int(minH))")
            }
        }
        if learnedAny,
           let bounds = displayObserver.usableBounds(for: spaceKey),
           let updatedFrames = store.collapseImpossibleEmptySplits(in: spaceKey, screenBounds: bounds) {
            SeamstressLog.layout.info("Collapsed over-constrained empty split in \(spaceKey.description, privacy: .public)")
            axBridge.applyFrames(updatedFrames, crossMonitorSafe: false)
            refreshSeamsAndUI()
        }
    }

    // MARK: - Maintenance, adoption & UI sync

    private func suppressSanitySweepForWakeGrace() {
        let target = ProcessInfo.processInfo.systemUptime + Self.postWakeSweepGrace
        if target > sanitySweepSuppressedUntil {
            sanitySweepSuppressedUntil = target
        }
    }

    /// Debounce topology re-apply after wake or monitor plug/unplug bursts (~0.6s settle).
    private func scheduleDebouncedTopologyReapply() {
        pendingTopologyReapply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.displayObserver.isSessionInactive else { return }
            _ = self.displayObserver.refresh()
            self.reapplyActiveSpaces()
            self.adoptExistingLayoutsIfNeeded()
            self.refreshSeamsAndUI()
        }
        pendingTopologyReapply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// On launch (and the first time each native Space is visited after launch), inspect
    /// existing on-screen window geometry and adopt close flush-tiled matches into the BSP
    /// store without moving or jittering any windows. Tileability verification runs off-main
    /// across per-PID queues so slow apps never stall the UI.
    private func adoptExistingLayoutsIfNeeded() {
        // Never probe while the screen is locked or displays are asleep — otherwise spaces
        // would be permanently marked probed while windows are off-screen/unavailable.
        guard !displayObserver.isSessionInactive else { return }

        let unprobed = displayObserver.displays.filter {
            !displayObserver.isDisplayAsleep($0.displayID) &&
            !probedSpaces.contains($0.spaceKey) &&
            store.tree(for: $0.spaceKey).isEmpty
        }
        guard !unprobed.isEmpty else { return }

        let onScreen = axBridge.onScreenNormalWindows()
        guard !onScreen.isEmpty else { return }
        let snapByID = Dictionary(uniqueKeysWithValues: onScreen.map { ($0.windowID, $0) })

        var proposals: [(spaceKey: SpaceKey, tree: LayoutTree)] = []
        var checkTargets: [WindowID: pid_t] = [:]

        for display in unprobed {
            let spaceKey = display.spaceKey
            let usable = display.usableFrameCG
            let candidates: [WindowCandidate] = onScreen.compactMap { snap in
                guard !store.isTiled(snap.windowID) else { return nil }
                guard !display.isNativeFullscreen(snap.bounds) else { return nil }
                let center = CGPoint(x: snap.bounds.midX, y: snap.bounds.midY)
                guard usable.contains(center) else { return nil }
                return WindowCandidate(windowID: snap.windowID, frame: snap.bounds)
            }

            guard let reconstructed = LayoutReconstructor.reconstruct(windows: candidates, in: usable) else {
                probedSpaces.insert(spaceKey)
                continue
            }

            proposals.append((spaceKey, reconstructed))
            for wid in reconstructed.allWindowIDs {
                if let snap = snapByID[wid] {
                    checkTargets[wid] = snap.ownerPID
                }
            }
        }

        guard !proposals.isEmpty else { return }

        adoptionGeneration &+= 1
        let generation = adoptionGeneration
        let targets = checkTargets.map { (windowID: $0.key, pid: $0.value) }

        axBridge.checkTileabilityBatchAsync(targets, timeout: 0.6) { [weak self] results in
            guard let self, self.isRunning,
                  self.adoptionGeneration == generation,
                  !self.displayObserver.isSessionInactive else {
                return
            }

            var needsRetry = false
            var adoptedAny = false

            for proposal in proposals {
                let spaceKey = proposal.spaceKey
                guard !self.probedSpaces.contains(spaceKey),
                      self.store.tree(for: spaceKey).isEmpty else {
                    continue
                }

                var sawTransientFailure = false
                var sawNonStandard = false
                for wid in proposal.tree.allWindowIDs {
                    let ownerName = snapByID[wid]?.ownerName ?? "?"
                    switch results[wid] ?? .unavailable {
                    case .tileable:
                        break
                    case .nonStandard:
                        SeamstressLog.layout.info("Skipped adoption in \(spaceKey.description, privacy: .public): window \(wid) (\(ownerName, privacy: .public)) is non-standard")
                        sawNonStandard = true
                    case .unavailable:
                        SeamstressLog.layout.info("Deferring adoption in \(spaceKey.description, privacy: .public): AX unavailable/timed out for window \(wid) (\(ownerName, privacy: .public))")
                        sawTransientFailure = true
                    }
                    if sawNonStandard || sawTransientFailure { break }
                }

                if sawTransientFailure {
                    needsRetry = true
                    continue
                }
                self.probedSpaces.insert(spaceKey)
                guard !sawNonStandard else { continue }

                let adopted = self.store.adoptReconstructedTree(proposal.tree, for: spaceKey)
                for wid in adopted {
                    self.recordDeclaredMinSizeIfAvailable(for: wid)
                }
                if !adopted.isEmpty {
                    adoptedAny = true
                    SeamstressLog.layout.notice("Adopted \(adopted.count) existing tiled window(s) in \(spaceKey.description, privacy: .public)")
                }
            }

            if adoptedAny {
                self.refreshSeamsAndUI()
            }

            if needsRetry, self.adoptionRetryCount < 3 {
                self.adoptionRetryCount += 1
                self.pendingAdoptionRetry?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.adoptExistingLayoutsIfNeeded()
                }
                self.pendingAdoptionRetry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            }
        }
    }

    private func reapplyActiveSpaces() {
        var frames: [WindowID: CGRect] = [:]
        for entry in displayObserver.activeSpaces() {
            for (wid, rect) in store.frames(for: entry.spaceKey, screenBounds: entry.bounds) {
                frames[wid] = rect
            }
        }
        if !frames.isEmpty {
            axBridge.applyFrames(frames, crossMonitorSafe: true)
        }
    }

    /// Lightweight WindowServer-only sweep (zero AX IPC): clears tiled windows on active Spaces
    /// that closed, minimized, hid, or entered native macOS fullscreen without sending an AX event.
    private func runSanitySweep() {
        guard isRunning, !seamDragController.isActive, !windowDragController.isActive else { return }
        guard !displayObserver.isSessionInactive else { return }
        guard ProcessInfo.processInfo.systemUptime >= sanitySweepSuppressedUntil else { return }

        let awakeSpaces = displayObserver.displays.filter { !displayObserver.isDisplayAsleep($0.displayID) }
        guard !awakeSpaces.isEmpty else { return }

        let activeSpaceKeys = Set(awakeSpaces.map(\.spaceKey))
        let tiledOnActiveSpaces = store.allTiledWindowIDs.filter { wid in
            guard let key = store.spaceKey(for: wid) else { return false }
            return activeSpaceKeys.contains(key)
        }
        guard !tiledOnActiveSpaces.isEmpty else { return }

        let onScreenList = axBridge.onScreenNormalWindows()
        // During transient lock/sleep/reconfiguration states, WindowServer can momentarily
        // report zero on-screen normal windows; never wipe layouts on an empty snapshot.
        guard !onScreenList.isEmpty else { return }

        let onScreen = Dictionary(uniqueKeysWithValues: onScreenList.map { ($0.windowID, $0) })

        var affectedSpaces: Set<SpaceKey> = []
        let now = ProcessInfo.processInfo.systemUptime
        for wid in tiledOnActiveSpaces {
            guard let snap = onScreen[wid] else {
                let appKey = axBridge.appKey(for: wid)
                if let space = store.handleWindowUnavailable(wid, appKey: appKey, timestamp: now) {
                    SeamstressLog.layout.info("Sanity sweep cleared off-screen window \(wid) in \(space.description, privacy: .public)")
                    affectedSpaces.insert(space)
                }
                axBridge.forget(windowID: wid)
                continue
            }
            if let key = store.spaceKey(for: wid),
               let display = displayObserver.display(for: key) {
                let center = CGPoint(x: snap.bounds.midX, y: snap.bounds.midY)
                let movedToOtherDisplay = displayObserver.displays.count > 1
                    && !display.fullFrameCG.contains(center)
                    && displayObserver.display(containing: center) != nil
                if display.isNativeFullscreen(snap.bounds) || movedToOtherDisplay {
                    if let space = store.handleWindowUnavailable(wid) {
                        let reason = movedToOtherDisplay ? "moved-display" : "fullscreen"
                        SeamstressLog.layout.info("Sanity sweep cleared \(reason, privacy: .public) window \(wid) in \(space.description, privacy: .public)")
                        affectedSpaces.insert(space)
                    }
                    axBridge.forget(windowID: wid)
                }
            }
        }

        if !affectedSpaces.isEmpty {
            applyFramesIfActive(spaces: affectedSpaces)
            refreshSeamsAndUI()
        }
    }

    private func applyFramesIfActive(spaces: Set<SpaceKey>, excluding excludedID: WindowID? = nil) {
        var frames: [WindowID: CGRect] = [:]
        for space in spaces {
            guard let bounds = displayObserver.usableBounds(for: space) else { continue }
            for (wid, rect) in store.frames(for: space, screenBounds: bounds) where wid != excludedID {
                frames[wid] = rect
            }
        }
        if !frames.isEmpty {
            axBridge.applyFrames(frames, crossMonitorSafe: false)
        }
    }

    private func refreshSeamsAndUI() {
        let active = displayObserver.activeSpaces()
        let seams = store.visibleSeams(for: active)
        inputTap.updateVisibleSeams(seams)

        // Sync AXObserver PIDs and EventTap tiled state to apps that currently have tiled windows,
        // and warm appKey caches so quit history still identifies apps after process exit.
        let tiledIDs = store.allTiledWindowIDs
        var pids: Set<pid_t> = []
        for wid in tiledIDs {
            if let pid = axBridge.pid(for: wid) {
                pids.insert(pid)
            }
            _ = axBridge.appKey(for: wid)
        }
        inputTap.updateTiledState(windowIDs: tiledIDs, pids: pids)
        eventMonitor.syncObservedPIDs(pids)

        updateMenuState()
    }

    private func updateMenuState() {
        tiledWindowCount = store.allTiledWindowIDs.count
        if let display = currentMenuDisplay() {
            let tree = store.tree(for: display.spaceKey)
            activeDisplayBounds = display.usableFrameCG
            activeDisplayName = display.localizedName
            activeMinimapTiles = tree.leafPlacements(in: display.usableFrameCG).map { leaf in
                let info = leaf.windowID.flatMap { axBridge.appInfo(for: $0) }
                return MinimapTile(
                    id: leaf.leafID,
                    windowID: leaf.windowID,
                    frame: leaf.frame,
                    appName: info?.appName,
                    appIcon: info?.icon
                )
            }
            canEqualizeCurrentSpace = Self.hasUnequalSplit(in: tree.root)
        } else {
            activeDisplayBounds = .zero
            activeDisplayName = ""
            activeMinimapTiles = []
            canEqualizeCurrentSpace = false
        }
    }

    private static func hasUnequalSplit(in node: LayoutTree.Node) -> Bool {
        switch node {
        case .empty, .window:
            return false
        case .split(_, _, let ratio, let first, let second):
            if abs(ratio - 0.5) > 0.005 {
                return true
            }
            return hasUnequalSplit(in: first) || hasUnequalSplit(in: second)
        }
    }

    private func persistSavedFloatingFrames() {
        LayoutPersistence.saveFloatingFrames(store.savedFloatingFramesSnapshot())
    }

    private func currentMenuDisplay() -> DisplayInfo? {
        let mouseNS = NSEvent.mouseLocation
        let mouseCG = CoordinateSpace.flipY(mouseNS, primaryHeight: displayObserver.primaryScreenHeight)
        return displayObserver.display(containing: mouseCG) ?? displayObserver.displays.first
    }
}
