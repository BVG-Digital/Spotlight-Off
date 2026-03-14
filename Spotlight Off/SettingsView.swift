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
import UniformTypeIdentifiers

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var monitor: DriveMonitor
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            // Greyscale midnight base — matches WelcomeView palette.
            Color(white: 0.055).ignoresSafeArea()

            // Subtle gradient blooms so Liquid Glass sections have something to refract.
            GeometryReader { geo in
                RadialGradient(
                    colors: [Color(red: 0.25, green: 0.35, blue: 0.55).opacity(0.22), .clear],
                    center: .init(x: 0.80, y: 0.05),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.65
                ).ignoresSafeArea()
                RadialGradient(
                    colors: [Color(red: 0.30, green: 0.20, blue: 0.45).opacity(0.12), .clear],
                    center: .init(x: 0.10, y: 0.95),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.55
                ).ignoresSafeArea()
            }

            TabView(selection: $selectedTab) {
                GeneralTabView(monitor: monitor)
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(0)

                DrivesTabView(monitor: monitor)
                    .tabItem { Label("Drives", systemImage: "externaldrive") }
                    .tag(1)

                LogTabView()
                    .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
                    .tag(2)
            }
        }
        .frame(width: 500, height: 400)
        .onAppear { selectedTab = 0 }
    }
}

// MARK: - General Tab

private struct GeneralTabView: View {
    @ObservedObject var monitor: DriveMonitor
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @AppStorage("spotlightoff.notificationsEnabled") private var notificationsEnabled = true

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
                Toggle("Show notifications", isOn: $notificationsEnabled)
            } footer: {
                Text("If Full Disk Access is not granted, administrator approval will be required each time a drive is processed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                            onRemove:  { monitor.removeEntry(entry) },
                            onExclude: { monitor.addExclusion(mountPath: entry.mountPath) },
                            onRetry:   entry.status == .failed && monitor.mountedPaths.contains(entry.mountPath)
                                           ? { monitor.reprocess(entry: entry) }
                                           : nil,
                            onReEnable: entry.status != .failed && monitor.mountedPaths.contains(entry.mountPath)
                                           ? { monitor.reEnableSpotlight(entry: entry) }
                                           : nil
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
    @State private var didCopy = false
    @ObservedObject private var store = LogStore.shared

    var body: some View {
        Form {
            Section {
                LogView()
                    .frame(minHeight: 240)
                    .listRowInsets(EdgeInsets())
            } header: {
                HStack(spacing: 6) {
                    Text("Activity Log")
                    if !store.entries.isEmpty {
                        Text("(\(store.entries.count))")
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    // Icon-only toolbar buttons — matching Console.app's style.
                    // Tooltips (.help) provide labels on hover for accessibility.
                    Button {
                        let text = LogStore.shared.entries
                            .map(\.text)
                            .joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        didCopy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            didCopy = false
                        }
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(didCopy ? Color.green : Color.secondary)
                            .animation(.easeInOut(duration: 0.15), value: didCopy)
                    }
                    .buttonStyle(.borderless)
                    .disabled(LogStore.shared.entries.isEmpty)
                    .help("Copy All — copy log entries to clipboard")

                    Button {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "Spotlight Off Log.txt"
                        panel.allowedContentTypes = [UTType.plainText]
                        let handler: (NSApplication.ModalResponse) -> Void = { response in
                            guard response == .OK, let url = panel.url else { return }
                            let text = LogStore.shared.entries.map(\.text).joined(separator: "\n")
                            try? text.write(to: url, atomically: true, encoding: .utf8)
                        }
                        if let window = NSApp.keyWindow {
                            panel.beginSheetModal(for: window, completionHandler: handler)
                        } else {
                            panel.begin(completionHandler: handler)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(LogStore.shared.entries.isEmpty)
                    .help("Export — save log to a text file")

                    Divider()
                        .frame(height: 10)

                    Button {
                        LogStore.shared.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .disabled(LogStore.shared.entries.isEmpty)
                    .help("Clear — remove all log entries")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.top, 8)
    }
}

// MARK: - History Row

private struct HistoryRowView: View {
    let entry: DriveEntry
    let onRemove: () -> Void
    let onExclude: () -> Void
    var onRetry: (() -> Void)? = nil
    var onReEnable: (() -> Void)? = nil

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
                HStack(spacing: 4) {
                    Text(entry.mountPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let fmt = entry.format {
                        Text(fmt)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
            Spacer()
            // Show action buttons on hover; date otherwise.
            if isHovering {
                HStack(spacing: 10) {
                    // Retry — only shown for failed entries on currently-mounted drives.
                    if let retry = onRetry {
                        Button(action: retry) {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.borderless)
                        .help("Retry — attempt to disable Spotlight indexing again")
                    }
                    // Re-enable — shown for disabled/alreadyDisabled on mounted drives.
                    if let reEnable = onReEnable {
                        Button(action: reEnable) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.blue.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                        .help("Re-enable Spotlight — indexing will be disabled again on next connect unless excluded")
                    }
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
                if store.entries.isEmpty {
                    Text("No activity yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                        .padding(8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.entries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
            }
            .onAppear {
                if let last = store.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: store.entries.count) { _, _ in
                if let last = store.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: LogEntry

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Splits "[HH:MM:SS AM/PM] message" into its two parts.
    /// Prepends the date to the timestamp when the entry is not from today.
    private var parts: (timestamp: String, message: String) {
        let text = entry.text
        guard text.hasPrefix("["), let end = text.firstIndex(of: "]") else {
            return ("", text)
        }
        let timeOnly = String(text[text.index(after: text.startIndex)..<end]) // HH:MM:SS AM
        let msg = String(text[text.index(after: end)...])
            .trimmingCharacters(in: .whitespaces)

        let cal = Calendar.current
        let ts: String
        if cal.isDateInToday(entry.date) {
            ts = "[\(timeOnly)]"
        } else if cal.isDateInYesterday(entry.date) {
            ts = "[Yesterday \(timeOnly)]"
        } else {
            ts = "[\(Self.dayFormatter.string(from: entry.date)) \(timeOnly)]"
        }
        return (ts, msg)
    }

    /// Semantic color based on message content.
    private var messageColor: Color {
        let msg = parts.message.lowercased()
        if msg.contains("error") || msg.contains("failed") || msg.contains("failure") {
            return Color(red: 1.0, green: 0.35, blue: 0.35)   // soft red
        }
        if msg.contains("successfully") || msg.contains("already disabled") || msg.hasSuffix(": disabled") {
            return Color(red: 0.35, green: 0.85, blue: 0.50)  // soft green
        }
        // Verbose mdutil detail lines — de-emphasise them
        if msg.hasPrefix("mdutil") || msg.hasPrefix("using path") {
            return Color.secondary.opacity(0.6)
        }
        return Color.secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(parts.timestamp)
                .foregroundStyle(.tertiary)
            Text(parts.message)
                .foregroundStyle(messageColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, design: .monospaced))
        .textSelection(.enabled)
    }
}
