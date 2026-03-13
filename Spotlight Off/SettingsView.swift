// SettingsView.swift
// Settings window UI — three-tab layout using Form + Section.
//
// Diverges from upstream (titleunknown/Spotlight-Off) in the following ways:
//
// • TabView (General / Drives / Log) replaces the upstream's single scrolling
//   VStack. The tabbed layout matches System Settings conventions and avoids
//   the need to scroll through unrelated content.
//
// • Form + Section with .formStyle(.grouped) gives each tab the standard
//   macOS grouped-list appearance used in System Settings, rather than the
//   upstream's hand-rolled HStack/VStack headers and plain List.
//
// • .scrollContentBackground(.hidden) is applied to every Form. Without it,
//   the List backing the Form renders its own scroll-content background layer
//   that differs subtly from NSColor.windowBackgroundColor, producing
//   inconsistent shading between sections and empty space within the same tab.
//
// • foregroundStyle replaces the deprecated foregroundColor throughout.
//
// • Drive exclusions UI is added to the Drives tab: right-click a processed
//   drive to exclude it from future processing, or remove an exclusion from
//   the Excluded Drives section. Not present in upstream.
//
// • "Processed Drives" renamed to "Drive History" — more accurate now that the
//   section can contain disabled, already-disabled, and failed entries.
//
// • Excluded drives are filtered out of Drive History so they only appear in the
//   Excluded Drives section. The filter is view-only; history data is preserved
//   so entries reappear if an exclusion is later removed.
//
// • HistoryRowView displays a per-row status icon reflecting DriveStatus:
//   green filled checkmark (.disabled), gray outlined checkmark (.alreadyDisabled),
//   red exclamation mark (.failed). Helps the user spot drives that need attention.

import ServiceManagement
import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var monitor: DriveMonitor

    var body: some View {
        TabView {
            GeneralTabView(monitor: monitor)
                .tabItem { Label("General", systemImage: "gearshape") }

            DrivesTabView(monitor: monitor)
                .tabItem { Label("Drives", systemImage: "externaldrive") }

            LogTabView()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 500, height: 400)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - General Tab

private struct GeneralTabView: View {
    @ObservedObject var monitor: DriveMonitor
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            // MARK: About
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Spotlight Off")
                                .font(.headline)
                            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                                Text("v\(version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("Automatically disables Spotlight indexing on external drives.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .padding(.vertical, 6)

                HStack {
                    Text("Forked from")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("titleunknown/Spotlight-Off",
                         destination: URL(string: "https://github.com/titleunknown/Spotlight-Off")!)
                        .font(.caption)
                }

                HStack {
                    Text("Fork \u{0026} improvements")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("BVG Digital",
                         destination: URL(string: "https://github.com/BVG-Digital/Spotlight-Off")!)
                        .font(.caption)
                }
            } footer: {
                Text("Released under the MIT License.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: Settings
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        } catch {
                            LogStore.shared.log("Failed to update launch at login setting: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } footer: {
                Text("If Full Disk Access is not granted, administrator approval will be required each time a drive is processed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(NSColor.windowBackgroundColor))
        .padding(.top, 8)
    }
}

// MARK: - Drives Tab

private struct DrivesTabView: View {
    @ObservedObject var monitor: DriveMonitor

    /// History entries that are not currently excluded — excluded drives are shown
    /// only in the Excluded Drives section below to avoid appearing in both lists.
    private var visibleHistory: [DriveEntry] {
        monitor.history.filter { !monitor.exclusions.contains($0.mountPath) }
    }

    var body: some View {
        Form {
            Section {
                if visibleHistory.isEmpty {
                    emptyHistoryPlaceholder
                } else {
                    ForEach(visibleHistory) { entry in
                        HistoryRowView(
                            entry: entry,
                            onRemove: { monitor.removeEntry(entry) },
                            onExclude: { monitor.addExclusion(mountPath: entry.mountPath) }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Drive History")
                    Spacer()
                    if !monitor.history.isEmpty {
                        Button("Clear All") { monitor.clearHistory() }
                            .buttonStyle(.borderless)
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.red)
                    }
                }
            } footer: {
                if !visibleHistory.isEmpty {
                    Text("Hover over a drive to remove it from history or exclude it. Excluding re-enables Spotlight immediately and prevents future processing.")
                }
            }

            if !monitor.exclusions.isEmpty {
                Section {
                    ForEach(monitor.exclusions, id: \.self) { path in
                        ExclusionRowView(path: path) {
                            monitor.removeExclusion(path)
                        }
                    }
                } header: {
                    Text("Excluded Drives")
                } footer: {
                    Text("These drives will never be processed. Click \u{00D7} to remove an exclusion \u{2014} if the drive is connected, Spotlight will be re-disabled automatically.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(NSColor.windowBackgroundColor))
        .padding(.top, 8)
    }

    private var emptyHistoryPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("No drives processed yet")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Text("Connect an external drive and Spotlight Off\nwill disable indexing automatically.")
                .foregroundStyle(.secondary.opacity(0.7))
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Log Tab

private struct LogTabView: View {
    var body: some View {
        Form {
            Section {
                LogView()
                    .frame(minHeight: 240)
                    .listRowInsets(EdgeInsets())
            } header: {
                HStack(spacing: 6) {
                    Text("Activity Log")
                    Spacer()
                    // Copy All — utility action, grey, disabled when log is empty.
                    Button("Copy All") {
                        let text = LogStore.shared.entries
                            .map(\.text)
                            .joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .disabled(LogStore.shared.entries.isEmpty)

                    // Separator between utility and destructive actions.
                    Divider()
                        .frame(height: 10)

                    // Clear — destructive, red, matching "Clear All" in Drives tab.
                    Button("Clear") { LogStore.shared.clear() }
                        .buttonStyle(.borderless)
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.red)
                        .disabled(LogStore.shared.entries.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(NSColor.windowBackgroundColor))
        .padding(.top, 8)
    }
}

// MARK: - History Row

private struct HistoryRowView: View {
    let entry: DriveEntry
    let onRemove: () -> Void
    let onExclude: () -> Void

    @State private var isHovering = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    @ViewBuilder
    private var statusImage: some View {
        switch entry.status {
        case .disabled:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Spotlight indexing disabled")
        case .alreadyDisabled:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .help("Spotlight indexing was already disabled")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .help("Could not disable Spotlight indexing — see Log for details")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            statusImage
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .fontWeight(.medium)
                Text(entry.mountPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            // Show action buttons on hover; date otherwise.
            if isHovering {
                HStack(spacing: 10) {
                    Button(action: onExclude) {
                        Image(systemName: "nosign")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                    .help("Exclude — re-enables Spotlight and skips this drive in future")
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from history")
                }
            } else {
                Text(Self.dateFormatter.string(from: entry.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - Exclusion Row

private struct ExclusionRowView: View {
    let path: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "nosign")
                .foregroundStyle(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.subheadline)
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove exclusion")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - Log View

struct LogView: View {
    @ObservedObject var store = LogStore.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.entries) { entry in
                        Text(entry.text)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: store.entries.count) { _, _ in
                if let last = store.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
