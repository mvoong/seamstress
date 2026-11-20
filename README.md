# Seamstress

A lightweight, mouse-driven macOS tiling window manager built around floating-by-default windows, Option-drag splitting, and real-time flush seam resizing.

## Behavior

- **Unmanaged by default:** New windows open wherever macOS places them.
- **Native Spaces & multi-monitor:** Each `(display, native Space)` tracks its own flush (`0px` gap) binary split tree (BSP).
- **`⌥` + Drag** (works passively with both titlebar drag and macOS drag-anywhere gestures; press or release `⌥` mid-drag to engage or cancel):
  - **Empty screen or empty slot:** Center fills 100%; dragging near an edge (~18% band) takes 50% on that edge and leaves the opposite half empty.
  - **Occupied slot:** Center zone (~36%) swaps (or replaces and floats the displaced window back to its pre-tiled size); outer edges split 50/50.
- **Normal Drag (without `⌥`):** Detaches a tiled window back to floating, restores its pre-tiled size anchored under the cursor, and leaves its slot empty.
- **Closing / Minimizing a Tiled Window:** Automatically expands neighboring windows to fill the vacated space.
- **Hover Seam to Resize:** Hovering within ±5pt of any flush seam reveals a subtle hairline + grip handle and resize cursor (automatically suppressed whenever a floating window covers that seam).
  - Drag to resize windows in **real time** (per-PID serial async AX queues with latest-frame coalescing and temporary `AXEnhancedUserInterface` disable).
  - Drag past **90%** toward an empty slot, or **double-click** the seam, to collapse an empty slot (double-clicking between two occupied panes resets the split to 50/50).

## Build, Test & Install

```bash
swift test
./scripts/install.sh
```

`scripts/install.sh` builds a host-architecture (`arm64`) Release binary into `build/local-install/`, generates `AppIcon.icns`, signs with `Developer ID Application` (override with `SEAMSTRESS_SIGN_ID`), verifies the signature, and installs to `/Applications/Seamstress.app`.

Grant Accessibility permission when prompted on first launch (System Settings → Privacy & Security → Accessibility).
