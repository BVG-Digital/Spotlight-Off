// Spotlight_OffApp.swift
// App entry point, AppDelegate, and menu bar UI.
//
// Diverges from upstream (titleunknown/Spotlight-Off) in the following ways:
//
// • MenuBarExtra + Settings scene replace the upstream's manual NSStatusItem /
//   NSWindow / NSHostingView approach. This is cleaner SwiftUI but requires
//   macOS 14+ (upstream targets macOS 13). Tested and working on macOS 26 Tahoe.
//   On Tahoe, the system log may emit a harmless "[NSStatusItemView] No matching
//   scene to invalidate" warning due to changes in how Tahoe handles SwiftUI
//   scene lifecycle — this does not affect functionality. As a guard against
//   this becoming a functional issue in a future release, MenuBarView checks
//   0.5s after the settings button is tapped whether a window actually appeared;
//   if not, AppDelegate.openSettingsDirectly() opens it via NSWindow directly,
//   matching the upstream's approach as a silent fallback.
//
// • @Environment(\.openSettings) is used to open the settings window, which
//   is also macOS 14-only. If you need macOS 13 support, revert to the
//   upstream's manual NSWindow pattern (see AppDelegate.openSettings in the
//   original repo).
//
// • @MainActor on AppDelegate ensures DriveMonitor (also @MainActor) can be
//   created safely at the call site without isolation errors.
//
// • scanMountedVolumes() is called at launch to handle drives that were
//   already connected before the app started — not present in upstream.
//
// • UNUserNotificationCenter authorization is requested at launch to support
//   system notifications when a drive is processed.
//
// • Settings windows are assigned .floating level so they stay above other
//   apps' windows when the user switches away. Applied in both the SwiftUI
//   scene path and the NSWindow fallback.
//
// • MenuBarView splits connected drives into two groups: active drives (Spotlight
//   disabled, submenu offers "Exclude This Drive") and excluded connected drives
//   (Spotlight enabled, submenu offers "Remove Exclusion"). This lets the user
//   control exclusions without opening Settings.

import SwiftUI
import UserNotifications

// MARK: - App Entry Point

@main
struct SpotlightOffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: appDelegate.driveMonitor)
        } label: {
            Image(systemName: appState.iconName)
                .accessibilityLabel("Spotlight Off")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(monitor: appDelegate.driveMonitor)
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let driveMonitor = DriveMonitor()

    // Fallback settings window used when the SwiftUI Settings scene lifecycle
    // is unreliable. Kept alive (isReleasedWhenClosed = false) so it can be
    // raised rather than recreated on subsequent calls.
    private var fallbackSettingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        driveMonitor.start()
        // Scan volumes already mounted before the app started (e.g. after a restart).
        driveMonitor.scanMountedVolumes()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Opens the settings window directly via NSWindow, bypassing the SwiftUI
    /// Settings scene entirely. Called automatically when the scene-based path
    /// fails to produce a visible window (e.g. if MenuBarExtra scene lifecycle
    /// breaks in a future macOS release). Also callable directly if needed.
    func openSettingsDirectly() {
        if let window = fallbackSettingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView: SettingsView(monitor: driveMonitor))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Spotlight Off"
        window.contentView = hosting
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        fallbackSettingsWindow = window
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @ObservedObject var monitor: DriveMonitor
    @Environment(\.openSettings) private var openSettings

    /// Connected drives with Spotlight disabled — listed in order of last seen.
    private var activeDrives: [DriveEntry] {
        monitor.history.filter {
            monitor.mountedPaths.contains($0.mountPath) &&
            !monitor.exclusions.contains($0.mountPath)
        }
    }

    /// Connected drives on the exclusion list — Spotlight is enabled on these.
    private var excludedConnected: [String] {
        monitor.mountedPaths.filter { monitor.exclusions.contains($0) }.sorted()
    }

    /// Returns a display name for a mount path, falling back to the last path component.
    private func driveName(for mountPath: String) -> String {
        monitor.history.first(where: { $0.mountPath == mountPath })?.name
            ?? URL(fileURLWithPath: mountPath).lastPathComponent
    }

    var body: some View {
        Text("Spotlight Off \u{2014} Active")
            .foregroundStyle(.secondary)

        Divider()

        if activeDrives.isEmpty && excludedConnected.isEmpty {
            Text("No drives connected")
                .foregroundStyle(.secondary)
        } else {
            // Active drives — Spotlight is disabled on these.
            ForEach(activeDrives.prefix(5)) { entry in
                Menu {
                    Button("Exclude This Drive") {
                        monitor.addExclusion(mountPath: entry.mountPath)
                    }
                } label: {
                    Label(entry.name, systemImage: "checkmark.circle.fill")
                }
            }
            if activeDrives.count > 5 {
                Text("  + \(activeDrives.count - 5) more\u{2026}")
                    .foregroundStyle(.secondary)
            }

            // Excluded drives that are currently connected — Spotlight is on.
            if !excludedConnected.isEmpty {
                if !activeDrives.isEmpty { Divider() }
                ForEach(excludedConnected, id: \.self) { path in
                    Menu {
                        Button("Remove Exclusion") {
                            monitor.removeExclusion(path)
                        }
                    } label: {
                        Label(driveName(for: path), systemImage: "nosign")
                    }
                }
            }
        }

        Divider()

        Button("History & Settings\u{2026}") {
            openSettings()
            // Defer to next run-loop tick so the window exists before we raise it.
            // orderFrontRegardless is needed because this app runs as .accessory.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows
                    .filter { $0.canBecomeKey && !($0 is NSPanel) }
                    .forEach {
                        $0.level = .floating
                        $0.makeKeyAndOrderFront(nil)
                        $0.orderFrontRegardless()
                    }
                // Guard against MenuBarExtra scene lifecycle failure (observed on macOS 26
                // Tahoe): if no key-capable window is visible after a short delay, fall
                // back to opening the settings window directly via NSWindow.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let hasVisible = NSApp.windows.contains { $0.canBecomeKey && $0.isVisible && !($0 is NSPanel) }
                    if !hasVisible {
                        (NSApp.delegate as? AppDelegate)?.openSettingsDirectly()
                    }
                }
            }
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Spotlight Off") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
