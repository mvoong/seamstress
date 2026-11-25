# Changelog

All notable changes to Seamstress are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.3] - 2026-11-25

### Fixed
- Prevented macOS 15+ native Option-drag tiling (`hotzoneDrag`) from hijacking Seamstress `⌥`-drags by stripping `⌥` from `leftMouseDragged`, `leftMouseUp`, and `flagsChanged` while an active window move is in progress (leaving in-app Option-drags untouched).
- Guarded settled minimum-size learning so windows displaced off their target span or still animating can no longer poison learned minimum window sizes.

## [0.1.2] - 2026-11-25

### Added
- Sparkle 2 automatic updates (`Check for Updates…` and `Check for updates automatically` in the menu bar popover, backed by EdDSA-signed updates at `https://seamstress.voong.io/appcast.xml`).
- Built-in **Drag windows from anywhere (`⌃⌘`)** toggle in the menu bar popover that configures macOS's global `NSWindowShouldDragOnGesture` setting.
- Interactive web playground and marketing site at `https://seamstress.voong.io`.

### Changed
- Clarified the menu bar popover cheat sheet by replacing `⌥ / ⌃⌘ Drag` with `⌥ + Drag` and showing `⌃⌘ + Drag` on its own row when Drag Anywhere is enabled.

## [0.1.1] - 2026-11-25

### Fixed
- Prevented `removeWindowAndCollapse` from promoting an `.empty` sibling into a phantom gap when an adjacent tiled window closes, detaches, or moves.
- Collapsed the vacated slot when moving a tiled window into a non-sibling empty slot or across displays instead of leaving a new empty slot behind, with WYSIWYG drop previews in `DropPlanner`.
- Snapped tiled windows back to their slot if an Option-drag is released without a valid drop zone (for example, inside the menu bar).
- Evicted tiled windows from their previous Space during the sanity sweep when moved onto another display outside Seamstress.

## [0.1.0] - 2026-11-24

### Added
- Mouse-driven BSP tiling for macOS 13+ with `⌥`-drag and `⌃⌘`-drag snapping (fill, edge split, T-junction container split, center swap/replace, and own-slot shrink).
- Flush seam hover highlights, live single-seam and 4-way `┼` intersection resizing, magnetic detents (`50%`, `1/3`, `2/3`, co-linear alignment, `⇧` bypass), double-click collapse/equalize, and Force Touch haptics.
- Normal drag and manual edge-resize detach with saved pre-tiled floating size restoration and late-Option grace undo.
- `Esc` undo for active window drags and seam resizes while holding the mouse button.
- Per-Space layout history that automatically restores quit applications into their previous slots on relaunch when the Space is unchanged.
- Startup and first-Space-visit layout reconstruction from existing flush-tiled windows.
- Minimum window size awareness via WindowServer constraints and settled-size learning, with feasible-axis drop targeting and automatic collapse of impossible empty seams.
- Menu bar popover with interactive app-icon minimap, Equalize/Clear controls, optional hidden menu bar icon mode, and Launch at Login toggle.
- Sleep/lock/wake layout preservation and Option-click unfocused-window protection.
- Universal (`arm64` + `x86_64`) signed and notarized DMG release script.

[0.1.3]: https://github.com/mvoong/seamstress/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/mvoong/seamstress/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/mvoong/seamstress/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mvoong/seamstress/releases/tag/v0.1.0
