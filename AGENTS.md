# Seamstress

Lightweight, mouse-driven macOS tiling window manager (`com.example.seamstress`, macOS 13+, SwiftPM).

## Module Layout

- `Sources/SeamstressCore/`: Pure Swift core with zero AppKit/AX dependencies:
  - `Geometry.swift`: CG↔NS coordinate conversion, flush integer-aligned rect splitting, cursor-anchored detach restore.
  - `LayoutTree.swift`: BSP tree with `.empty`, `.window`, and `.split` nodes (`removeWindow` leaves an empty slot; `removeWindowAndCollapse` promotes the sibling to fill vacated space).
  - `DropPlanner.swift`: Snap-drag (`⌥`-drag / `⌃⌘`-drag) zone classification (split T-junctions `┬`/`┴`/`├`/`┤` split the parent container along the perpendicular axis; empty center=fill / edge=half; occupied center=swap / outer=split; own edge=shrink).
  - `SeamGeometry.swift`: Flush `10pt` (`±5pt`) seam hit strips, hit-testing, ratio clamping, and `> 90%` collapse-to-empty detection.
  - `SpaceLayoutStore.swift`: Per-`(displayUUID, spaceID)` tree store, saved pre-tiled floating frames, cross-monitor moves/swaps.
  - `LayoutReconstructor.swift`: Pure startup/first-Space-visit BSP reconstructor from on-screen window frames (14pt edge tolerance, floating-window guardrails).
  - `FrameCoalescer.swift`: Per-PID latest-frame coalescing state machine for live AX resize batches.
- `Sources/Seamstress/`: macOS menu bar runtime (`InputEventTap`, `AXWindowBridge`, `SkyLightBridge`, `DisplayObserver`, `WindowEventMonitor`, `DropPreviewOverlay`, `SeamHighlightOverlay`, `WindowManager`, `MenuBarPopoverView`, `AppDelegate`, `main`). Supports hiding the menu bar icon (`seamstress.showMenuBarIcon` in `UserDefaults`); reopening the app presents a standalone controls window.
- `Tests/SeamstressCoreTests/`: Headless XCTest suite covering all core invariants.
- `Resources/`: `Info.plist`, `Seamstress.entitlements`, and `generate-icon.swift`.
- `scripts/install.sh`: Builds host-arch (`arm64`) Release into `build/local-install/`, resolves the binary via `swift build --show-bin-path`, renders `AppIcon.icns`, signs with `Developer ID Application` (`SEAMSTRESS_SIGN_ID` override), verifies with `codesign --verify --deep --strict`, and installs to `/Applications/Seamstress.app`.

## Key Implementation Invariants

- **Coordinate systems:** CoreGraphics uses top-left origin (Y downward); AppKit (`NSScreen` / `NSPanel`) uses bottom-left origin (Y upward). All conversions go through `CoordinateSpace` anchored on `DisplayObserver.primaryScreenHeight`.
- **AX write ordering:** During live resizing, shrinking windows write `kAXSizeAttribute` before `kAXPositionAttribute` (preventing Dock/screen-edge clamping on horizontal seams); growing windows write `kAXPositionAttribute` before `kAXSizeAttribute`. Cross-monitor commits use `size → position → size`.
- **Minimum window sizes:** Never latch permanent minimum sizes from immediate mid-drag AX readbacks (async/laggy apps report pre-resize sizes and freeze seams). Instead, read declared limits once via SkyLight (`SLSWindowIteratorGetConstraints`) and learn settled minimums 140ms after mouse-up.
- **No main-thread AX IPC:** All AX frame writes run on per-PID `.userInteractive` serial queues fronted by `PerPIDFrameCoalescer`. Terminated PIDs are evicted on `didTerminateApplicationNotification`.
- **Z-order occlusion:** Seam hover and click-grab check front-to-back `CGWindowListCopyWindowInfo` so floating windows covering a seam or `┼` intersection are never intercepted.
- **SIP-safe Space & constraint queries:** `SkyLightBridge` dynamically loads read-only functions (`CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`, `CGSSetConnectionProperty` for `SetsCursorInBackground`, and `SLSWindowQueryWindows`/`SLSWindowIteratorGetConstraints`) via `dlopen`/`dlsym`.
- **Diagnostics:** Lightweight `os.Logger` under subsystem `com.example.seamstress` (`log stream --predicate 'subsystem == "com.example.seamstress"'`). Zero logging on hot `mouseMoved` / per-frame `mouseDragged` paths.

## Build, Test & Verify

```bash
swift test
bash -n scripts/install.sh
./scripts/install.sh
```

Unit tests verify pure layout, drop planning, seam geometry, and coalescing logic; live window dragging, real-time resizing, and multi-Space behavior require manual verification in `/Applications/Seamstress.app` launched via `/usr/bin/open` with Accessibility granted.
