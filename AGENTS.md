# Seamstress

Lightweight, mouse-driven macOS tiling window manager (`com.example.seamstress`).

## Layout

- `Sources/SeamstressCore/`: Pure Swift BSP tree (`LayoutTree`), Option-drag planner (`DropPlanner`), flush seam geometry (`SeamGeometry`), per-(display, native Space) state (`SpaceLayoutStore`), and per-PID latest-frame coalescer (`PerPIDFrameCoalescer`). Zero AppKit/AX dependencies so `swift test` runs headless in ~1s.
- `Sources/Seamstress/`: AppKit/SwiftUI menu bar app, `CGEventTap` on a dedicated `.userInteractive` thread (`InputEventTap`), read-only SkyLight Space bridge (`SkyLightBridge`), per-PID async AX frame writer (`AXWindowBridge`), `AXObserver` lifecycle monitor (`WindowEventMonitor`), overlays, and `WindowManager`.
- `Tests/SeamstressCoreTests/`: Unit tests for all core invariants.
- `scripts/install.sh`: Release `arm64` build, icon generation, Developer ID signing, verification, and install to `/Applications/Seamstress.app`.

## Verification

```bash
swift test
./scripts/install.sh
```

Unit tests cover the pure layout, hit-testing, seam clamping/collapse, and coalescer logic; live macOS window-drag and real-time AX resize behavior must be verified manually in `/Applications/Seamstress.app` with Accessibility granted.
