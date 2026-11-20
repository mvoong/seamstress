import Cocoa

// Single-instance guard: if another Seamstress process is already running, activate it
// (which opens its controls via applicationShouldHandleReopen) and exit cleanly.
let bundleID = Bundle.main.bundleIdentifier ?? "com.example.seamstress"
let currentPID = ProcessInfo.processInfo.processIdentifier
if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .first(where: { $0.processIdentifier != currentPID }) {
    existing.activate(options: [.activateIgnoringOtherApps])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
