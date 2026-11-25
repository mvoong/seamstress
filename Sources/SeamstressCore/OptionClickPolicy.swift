import CoreGraphics
import Foundation

/// Pure policy for neutralizing macOS's native "Option-click an inactive app to hide the
/// previously active app" behavior when Seamstress layouts are involved.
public enum OptionClickPolicy {
    /// Combined mask for `CGEventFlags.maskAlternate` plus device-dependent left/right Option
    /// bits (`NX_DEVICELALTKEYMASK = 0x20`, `NX_DEVICERALTKEYMASK = 0x40`).
    public static let optionFlagsRawMask: UInt64 =
        CGEventFlags.maskAlternate.rawValue | 0x20 | 0x40

    /// Returns true when a `leftMouseDown` event should have its Option modifier stripped before
    /// macOS processes it.
    ///
    /// We strip Option only when:
    /// - Option is held without Command or Control (so `⌘⌥` and `⌃⌥` clicks keep native semantics),
    /// - the click targets a window owned by a different (unfocused) app than `frontmostPID`, and
    /// - either the clicked window is tiled or the currently frontmost app owns a tiled window.
    ///
    /// This prevents macOS from hiding the currently focused app (and causing Seamstress to evict
    /// it from the layout) when Option-clicking or starting an Option-drag on an unfocused window,
    /// while preserving in-app Option-clicks and native Option-click-to-hide for unmanaged apps.
    public static func shouldStripOptionOnMouseDown(
        flags: CGEventFlags,
        clickedWindowID: WindowID?,
        clickedOwnerPID: Int32?,
        frontmostPID: Int32?,
        tiledWindowIDs: Set<WindowID>,
        tiledPIDs: Set<Int32>
    ) -> Bool {
        guard flags.contains(.maskAlternate),
              !flags.contains(.maskCommand),
              !flags.contains(.maskControl),
              let clickedWindowID,
              let clickedOwnerPID,
              let frontmostPID,
              clickedOwnerPID != frontmostPID else {
            return false
        }
        return tiledWindowIDs.contains(clickedWindowID) || tiledPIDs.contains(frontmostPID)
    }

    /// Returns true when `leftMouseDragged`, `leftMouseUp`, or `flagsChanged` during an active
    /// Seamstress-observed window drag should have Option stripped before macOS processes it.
    ///
    /// On macOS 15+ (Sequoia), holding `⌥` while dragging a window triggers native `WindowManager`
    /// Option-drag tiling (`EnableTilingOptionAccelerator` / `hotzoneDrag`), which races Seamstress's
    /// drop commit and animates the window into a native half-screen tile. Stripping `.maskAlternate`
    /// only while an actual window move is active leaves in-app Option-drags (e.g. Finder copy-drag
    /// or editor column selection) untouched.
    public static func shouldStripOptionDuringWindowDrag(
        flags: CGEventFlags,
        hasActiveWindowMove: Bool
    ) -> Bool {
        hasActiveWindowMove
            && flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)
    }

    /// Returns `flags` with `.maskAlternate` and device-dependent left/right Option bits cleared,
    /// leaving all other modifier bits intact.
    public static func strippingOption(from flags: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: flags.rawValue & ~optionFlagsRawMask)
    }
}
