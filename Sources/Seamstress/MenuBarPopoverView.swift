import ServiceManagement
import SeamstressCore
import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var windowManager: WindowManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !appState.isAccessibilityTrusted {
                accessibilityBanner
            }

            if !windowManager.activeLayoutLeaves.isEmpty, windowManager.activeDisplayBounds.width > 1 {
                layoutMiniMap
            }

            Divider()

            controlsSection

            Divider()

            cheatSheet

            Divider()

            HStack {
                Text("v\(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit Seamstress") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Seamstress")
                    .font(.headline)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(appState.isEnabled && appState.isAccessibilityTrusted ? Color.accentColor : Color.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { appState.isEnabled },
                set: { appState.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!appState.isAccessibilityTrusted)
        }
    }

    private var statusSubtitle: String {
        if !appState.isAccessibilityTrusted {
            return "Accessibility permission required"
        }
        if !appState.isEnabled {
            return "Paused"
        }
        let count = windowManager.tiledWindowCount
        return count == 0 ? "Active · no tiled windows" : "Active · \(count) tiled"
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Grant Accessibility permission so Seamstress can snap windows on Option-drag and resize split seams.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Request Permission") {
                    appState.requestAccessibility()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Open Settings") {
                    appState.openAccessibilitySettings()
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var layoutMiniMap: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Current Space")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if windowManager.activeLayoutLeaves.contains(where: { !$0.isEmpty }) {
                    Button("Clear Layout") {
                        windowManager.resetCurrentSpaceLayout()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            GeometryReader { geo in
                let bounds = windowManager.activeDisplayBounds
                let sx = geo.size.width / max(bounds.width, 1)
                let sy = geo.size.height / max(bounds.height, 1)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))

                    ForEach(windowManager.activeLayoutLeaves, id: \.leafID) { leaf in
                        let rx = (leaf.frame.minX - bounds.minX) * sx
                        let ry = (leaf.frame.minY - bounds.minY) * sy
                        let rw = max(4, leaf.frame.width * sx - 2)
                        let rh = max(4, leaf.frame.height * sy - 2)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(leaf.isEmpty ? Color.clear : Color.accentColor.opacity(0.28))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(
                                        leaf.isEmpty ? Color.secondary.opacity(0.35) : Color.accentColor.opacity(0.8),
                                        style: StrokeStyle(lineWidth: 1, dash: leaf.isEmpty ? [3, 2] : [])
                                    )
                            )
                            .frame(width: rw, height: rh)
                            .offset(x: rx + 1, y: ry + 1)
                    }
                }
            }
            .frame(height: 68)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show menu bar icon", isOn: Binding(
                get: { appState.showMenuBarIcon },
                set: { appState.setShowMenuBarIcon($0) }
            ))
            .font(.subheadline)

            if !appState.showMenuBarIcon {
                Text("Reopen Seamstress from Spotlight or Finder to access controls.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Launch at login", isOn: Binding(
                get: { appState.launchAtLogin },
                set: { appState.setLaunchAtLogin($0) }
            ))
            .font(.subheadline)
        }
    }

    private var cheatSheet: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("⌥ / ⌃⌘ Drag", "Fill empty space, split edge, or swap center")
            row("Normal Drag", "Detach to floating & expand neighbors")
            row("Hover Seam", "Drag to resize · Double-click to collapse/50%")
        }
        .font(.caption)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private func row(_ key: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 88, alignment: .leading)
            Text(desc)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
