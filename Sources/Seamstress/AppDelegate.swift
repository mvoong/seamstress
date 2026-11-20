import ApplicationServices
import Cocoa
import ServiceManagement
import SwiftUI

final class AppState: ObservableObject {
    @Published var isEnabled: Bool = true
    @Published var showMenuBarIcon: Bool = true
    @Published var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @Published var launchAtLoginRequiresApproval: Bool = (SMAppService.mainApp.status == .requiresApproval)

    var onEnabledChanged: ((Bool) -> Void)?
    var onShowMenuBarIconChanged: ((Bool) -> Void)?

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "seamstress.enabled")
        onEnabledChanged?(enabled)
    }

    func setShowMenuBarIcon(_ show: Bool) {
        showMenuBarIcon = show
        UserDefaults.standard.set(show, forKey: "seamstress.showMenuBarIcon")
        onShowMenuBarIconChanged?(show)
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLoginItemsSettings() {
        if let primary = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
           NSWorkspace.shared.open(primary) {
            return
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings") {
            NSWorkspace.shared.open(fallback)
        }
    }

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        let enabled = (status == .enabled)
        let requiresApproval = (status == .requiresApproval)
        if launchAtLogin != enabled {
            launchAtLogin = enabled
        }
        if launchAtLoginRequiresApproval != requiresApproval {
            launchAtLoginRequiresApproval = requiresApproval
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginItemStatus()
        } catch {
            refreshLoginItemStatus()
        }
    }

    func refreshTrust() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
        }
        return trusted
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let windowManager = WindowManager()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var controlWindow: NSWindow?
    private var trustPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if UserDefaults.standard.object(forKey: "seamstress.enabled") != nil {
            appState.isEnabled = UserDefaults.standard.bool(forKey: "seamstress.enabled")
        }
        if UserDefaults.standard.object(forKey: "seamstress.showMenuBarIcon") != nil {
            appState.showMenuBarIcon = UserDefaults.standard.bool(forKey: "seamstress.showMenuBarIcon")
        }

        appState.onEnabledChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled && self.appState.isAccessibilityTrusted {
                self.windowManager.start()
            } else {
                self.windowManager.stop()
            }
            self.updateStatusIcon()
        }

        appState.onShowMenuBarIconChanged = { [weak self] show in
            guard let self else { return }
            if !show {
                self.popover?.performClose(nil)
            }
            self.statusItem?.isVisible = show
        }

        setupStatusItem()
        statusItem?.isVisible = appState.showMenuBarIcon

        if appState.refreshTrust() {
            if appState.isEnabled {
                windowManager.start()
            }
        } else {
            appState.requestAccessibility()
            startTrustPolling()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showControls()
            }
        }
        updateStatusIcon()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reopening Seamstress (Spotlight, Finder, `open`) brings up controls even when the
    /// menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        trustPollTimer?.invalidate()
        windowManager.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Seamstress — Click for controls, Option-click or right-click to pause/resume"
        }
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(appState: appState, windowManager: windowManager)
        )
        popover = pop
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let isActive = appState.isEnabled && appState.isAccessibilityTrusted
        button.image = Self.makeStatusBarIcon(active: isActive)
        button.appearsDisabled = !isActive
        if !appState.isAccessibilityTrusted {
            button.toolTip = "Seamstress — Accessibility permission required"
        } else if appState.isEnabled {
            button.toolTip = "Seamstress (Active) — Click for controls, Option-click or right-click to pause"
        } else {
            button.toolTip = "Seamstress (Paused) — Click for controls, Option-click or right-click to resume"
        }
    }

    private static func makeStatusBarIcon(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()

            let frame = rect.insetBy(dx: 1.5, dy: 3.0)
            let outer = NSBezierPath(roundedRect: frame, xRadius: 2.5, yRadius: 2.5)
            outer.lineWidth = 1.4
            outer.stroke()

            let splitX = frame.minX + 7.0
            let splitY = frame.midY

            let seams = NSBezierPath()
            seams.move(to: NSPoint(x: splitX, y: frame.minY))
            seams.line(to: NSPoint(x: splitX, y: frame.maxY))
            seams.move(to: NSPoint(x: splitX, y: splitY))
            seams.line(to: NSPoint(x: frame.maxX, y: splitY))
            seams.lineWidth = 1.2
            seams.stroke()

            if !active {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 2.5, y: rect.maxY - 2.5))
                slash.line(to: NSPoint(x: rect.maxX - 2.5, y: rect.minY + 2.5))
                slash.lineCapStyle = .round

                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .clear
                slash.lineWidth = 3.2
                slash.stroke()
                NSGraphicsContext.restoreGraphicsState()

                NSColor.black.setStroke()
                slash.lineWidth = 1.5
                slash.stroke()
            }

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Seamstress"
        return image
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if let event = NSApp.currentEvent,
           (event.type == .rightMouseUp || event.modifierFlags.contains(.option)),
           appState.isAccessibilityTrusted {
            if popover?.isShown == true {
                popover?.performClose(sender)
            }
            appState.setEnabled(!appState.isEnabled)
            return
        }

        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showControls() {
        if appState.showMenuBarIcon, statusItem?.isVisible == true {
            showPopover()
        } else {
            showControlWindow()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover else { return }
        _ = appState.refreshTrust()
        appState.refreshLoginItemStatus()
        windowManager.refreshForMenuPresentation()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showControlWindow() {
        _ = appState.refreshTrust()
        appState.refreshLoginItemStatus()
        windowManager.refreshForMenuPresentation()
        if let existing = controlWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: MenuBarPopoverView(appState: appState, windowManager: windowManager)
        )
        let win = NSWindow(contentViewController: hosting)
        win.title = "Seamstress"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controlWindow = win
    }

    private func startTrustPolling() {
        trustPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.appState.refreshTrust() {
                t.invalidate()
                self.trustPollTimer = nil
                if self.appState.isEnabled {
                    self.windowManager.start()
                }
                self.updateStatusIcon()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }
}
