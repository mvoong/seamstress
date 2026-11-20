# Seamstress

A lightweight, mouse-driven macOS tiling window manager built around floating-by-default windows, Option-drag splitting, and real-time flush seam resizing.

## Design Philosophy

- **Unmanaged by default:** New windows open wherever macOS places them. Seamstress never hijacks or rearranges windows until you explicitly tile them.
- **Relaunch layout adoption:** When Seamstress starts (and on the first visit to each Space), it inspects existing window frames and automatically reconstructs close flush-tiled arrangements (with their exact split ratios) into live BSP trees without moving windows, while leaving ordinary floating windows untouched.
- **Native macOS Spaces & multi-monitor:** Each `(display, native Space)` maintains its own flush (`0px` gap) binary split tree (BSP). SIP stays enabled; Seamstress uses read-only Space queries and never relies on virtual-workspace workarounds.
- **Responsive & low overhead:** Idle mouse movement performs zero Accessibility IPC. Live seam resizing runs off the main thread on per-process serial queues with latest-frame coalescing so sluggish apps never stall your cursor or other windows.

## Interactions

| Action | Behavior |
| --- | --- |
| **`⌥` + Drag** into empty screen / empty slot (center) | Fills 100% of the available empty space. |
| **`⌥` + Drag** into empty screen / empty slot (near an edge) | Takes 50% on that edge (left, right, top, or bottom) and leaves the opposite half as an empty slot. |
| **`⌥` + Drag** onto an occupied tiled window (outer bands) | Splits that pane 50/50 along the targeted edge. |
| **`⌥` + Drag** near a split's **T-junction** (`┬`, `┴`, `├`, `┤`) | Splits the entire parent split container 50/50 along that perpendicular axis (spanning across both child panes). |
| **`⌥` + Drag** onto an occupied tiled window (center ~36%) | Swaps two tiled windows, or replaces the tiled window with a floating window (restoring the displaced window to its pre-tiled size). |
| **`⌥` + Drag** a tiled window onto its own edge | Shrinks it to that half and leaves the opposite half empty. |
| **Release `⌥` mid-drag** | Cancels tiling preview and lets the window drop as floating. |
| **Normal Drag** (without `⌥`) on a tiled window | Detaches it back to floating, restores its pre-tiled size anchored under the cursor, and expands neighboring windows to fill the gap. Pressing `⌥` within 0.45s of starting restores the layout so you can still swap/re-split. |
| **Manual Edge Resize** on a tiled window's own edge | Detaches it cleanly and expands neighboring windows so no stale seam stays behind. |
| **Close / Minimize / Hide / Quit** a tiled window | Automatically collapses its split so neighboring windows expand to fill the vacated space. |
| **Hover Seam** (`±5pt` along any flush split line or `┼` intersection) | Shows a subtle hairline + grip handle and resize cursor (crosshair at 2-axis intersections; suppressed whenever a floating window sits in front of the seam). |
| **Drag Seam / `┼` Intersection** | Resizes all affected windows in real time (1-axis along a seam, or simultaneous 2-axis at a vertical+horizontal intersection), clamped to real window minimum sizes. |
| **Drag Seam > 90%** toward an empty slot | Previews and collapses the empty slot on release, expanding the occupied side to 100%. |
| **Double-click Seam** | Collapses an adjacent empty slot, or resets a split between two occupied panes to 50/50. |

Works passively with both standard titlebar dragging and macOS drag-anywhere gestures (`NSWindowShouldDragOnGesture` / `⌥⌘`-drag).

## Architecture

### `Sources/SeamstressCore` (Pure Swift, headless-testable)
- **`Geometry.swift`**: CoreGraphics ↔ AppKit coordinate conversions anchored on `primaryScreenHeight`, integer-aligned flush `CGRect` splitting (zero 1pt gaps or overlaps), and cursor-anchored floating size restoration.
- **`LayoutTree.swift`**: Value-type BSP tree supporting occupied and persistent empty leaves, fill, edge-split, swap, replace, detach-to-empty, auto-collapse on window close, and double-empty cleanup.
- **`DropPlanner.swift`**: Pure Option-drag hit-testing and drop-zone preview rect computation.
- **`SeamGeometry.swift`**: Flush `10pt` hit-strip extraction, seam hit-testing, minimum-extent ratio clamping, and `> 90%` empty-slot collapse detection.
- **`SpaceLayoutStore.swift`**: Manages per-`(displayUUID, nativeSpaceID)` trees, pre-tiled floating frames, and cross-monitor moves/swaps.
- **`LayoutReconstructor.swift`**: Pure guillotine-cut BSP reconstructor that converts existing flush-arranged windows into `LayoutTree`s on launch while ignoring floating windows.
- **`FrameCoalescer.swift`**: Per-PID latest-frame coalescing state machine for live resizing.

### `Sources/Seamstress` (macOS AppKit / SwiftUI runtime)
- **`InputEventTap.swift`**: `CGEventTap` running on a dedicated `.userInteractive` thread. `mouseMoved` does a pure in-memory rect check against visible seams with zero main-thread hops when away from seams. Swallows events only when interacting with an unoccluded seam.
- **`AXWindowBridge.swift`**: Fast `CGWindowListCopyWindowInfo` drag detection and front-to-back Z-order occlusion checks, plus per-PID serial async AX frame queues with latest-frame coalescing, temporary `AXEnhancedUserInterface` disable during drags/commits, and shrink-vs-grow (`size → position` vs. `position → size`) write ordering to avoid Dock/menu-bar clamping.
- **`SkyLightBridge.swift` & `DisplayObserver.swift`**: Dynamic `dlopen`/`dlsym` read-only queries for active native Spaces per display UUID and background cursor updates, refreshed on screen/Space notifications.
- **`WindowEventMonitor.swift`**: Attaches `AXObserver` only to PIDs that currently own tiled windows (close/minimize), plus `NSWorkspace` hide/terminate observers and a lightweight CG-only sanity sweep for fullscreen or vanished windows.
- **`DropPreviewOverlay.swift` & `SeamHighlightOverlay.swift`**: Non-activating, click-through `NSPanel` overlays with animations disabled (`CATransaction.setDisableActions(true)`) for instant visual feedback.
- **`WindowManager.swift`, `MenuBarPopoverView.swift`, `AppDelegate.swift`**: Menu bar app (`LSUIElement`), optional hidden menu bar icon (reopening Seamstress from Spotlight/Finder opens a standalone controls window), Accessibility permission gate with live polling, current-space layout minimap, and launch-at-login (`SMAppService.mainApp`).

## Build, Test & Install

Requirements: macOS 13+, Swift 5.9+ (Xcode Command Line Tools), and a `Developer ID Application` signing identity for stable Accessibility permissions across rebuilds.

```bash
# Run unit tests (pure Swift, ~10ms)
swift test

# Build Release (arm64), generate AppIcon.icns, sign, verify, and install to /Applications/Seamstress.app
./scripts/install.sh
```

Override the signing identity if needed:

```bash
SEAMSTRESS_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/install.sh
```

On first launch, open `/Applications/Seamstress.app` and grant **Accessibility** permission in **System Settings → Privacy & Security → Accessibility**. Seamstress detects the grant automatically without needing a relaunch.

## Troubleshooting

- **Seamstress does not respond to drags or seams:** Verify Accessibility is enabled for `/Applications/Seamstress.app` in System Settings. If you rebuilt with a different signing identity, remove and re-add Seamstress in Accessibility settings.
- **Launch from Finder / Spotlight / `open`:** Always launch `/Applications/Seamstress.app` via Launch Services (`/usr/bin/open /Applications/Seamstress.app`), not by running the raw binary directly from a terminal, so macOS attributes Accessibility trust to the app bundle.
