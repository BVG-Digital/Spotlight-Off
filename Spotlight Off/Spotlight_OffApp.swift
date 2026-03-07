import SwiftUI
import ServiceManagement

// MARK: - Data Model

struct DriveEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: String
    let date: Date

    init(name: String, path: String) {
        self.id   = UUID()
        self.name = name
        self.path = path
        self.date = Date()
    }
}

// MARK: - App Entry Point

@main
struct SpotlightOffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(monitor: appDelegate.driveMonitor)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let driveMonitor = DriveMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        driveMonitor.start()
    }

    // MARK: Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.badge.xmark",
                                   accessibilityDescription: "Spotlight Off")
            button.image?.isTemplate = true
        }
        buildMenu()
        driveMonitor.onHistoryChanged = { [weak self] in
            DispatchQueue.main.async { self?.buildMenu() }
        }
    }

    func buildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Spotlight Off — Active", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let history = driveMonitor.history
        if history.isEmpty {
            let empty = NSMenuItem(title: "No drives processed yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in history.prefix(5) {
                let item = NSMenuItem(title: "✓  \(entry.name)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.toolTip   = entry.path
                menu.addItem(item)
            }
            if history.count > 5 {
                let more = NSMenuItem(title: "  + \(history.count - 5) more…", action: nil, keyEquivalent: "")
                more.isEnabled = false
                menu.addItem(more)
            }
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "History & Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Spotlight Off",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Drive Monitor

class DriveMonitor: ObservableObject {
    @Published var history: [DriveEntry] = []
    var onHistoryChanged: (() -> Void)?

    private let historyKey = "spotlightoff.history"

    init() { loadHistory() }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeMounted(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
    }

    // MARK: Volume Mounted

    @objc private func volumeMounted(_ notification: NSNotification) {
        guard let path = notification.userInfo?["NSDevicePath"] as? String else { return }
        print("[SpotlightOff] Volume mounted: \(path)")

        let url = URL(fileURLWithPath: path)
        guard isExternalVolume(url) else {
            print("[SpotlightOff] Skipped (not an external volume): \(path)")
            return
        }

        // On macOS Big Sur+, /Volumes/X is a firmlink to /System/Volumes/Data/Volumes/X.
        // These are NOT symlinks — realpath() and canonicalPath don't follow firmlinks.
        // We construct the real path manually, which is always predictable.
        let resolvedPath: String
        if path.hasPrefix("/Volumes/") {
            let candidate = "/System/Volumes/Data" + path
            if FileManager.default.fileExists(atPath: candidate) {
                resolvedPath = candidate
            } else {
                resolvedPath = path
            }
        } else {
            resolvedPath = path
        }
        print("[SpotlightOff] Resolved path: \(resolvedPath)")

        let name = url.lastPathComponent.isEmpty ? "External Drive" : url.lastPathComponent
        print("[SpotlightOff] Accepted — scheduling disable for: \(name)")

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.handleVolume(path: resolvedPath, name: name)
        }
    }

    // MARK: Volume Filtering
    // Accepts any local, non-internal, non-root volume.
    // We intentionally do NOT require volumeIsRemovable because many
    // bus-powered and SSD external drives don't set that flag.

    private func isExternalVolume(_ url: URL) -> Bool {
        guard let vals = try? url.resourceValues(forKeys: [
            .volumeIsRootFileSystemKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsRemovableKey
        ]) else {
            print("[SpotlightOff] Could not read volume flags for \(url.path)")
            return false
        }

        let isRoot      = vals.volumeIsRootFileSystem ?? false
        let isInternal  = vals.volumeIsInternal       ?? false
        let isLocal     = vals.volumeIsLocal           ?? false
        let isRemovable = vals.volumeIsRemovable       ?? false

        print("[SpotlightOff] Flags — root:\(isRoot) internal:\(isInternal) local:\(isLocal) removable:\(isRemovable)")

        if isRoot   { return false }
        if !isLocal { return false }   // skip network volumes
        return true
    }

    // MARK: Spotlight Check & Disable

    private func handleVolume(path: String, name: String) {
        let enabled = isIndexingEnabled(path: path)
        print("[SpotlightOff] Indexing enabled for '\(name)': \(enabled)")

        guard enabled else {
            print("[SpotlightOff] Already disabled — nothing to do.")
            return
        }

        let ok = disableIndexing(path: path)
        print("[SpotlightOff] Disable succeeded: \(ok)")

        if ok {
            DispatchQueue.main.async { [weak self] in
                self?.addToHistory(name: name, path: path)
            }
        }
    }

    private func isIndexingEnabled(path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        p.arguments     = ["-s", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("[SpotlightOff] mdutil -s: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            return !out.lowercased().contains("disabled")
        } catch {
            print("[SpotlightOff] mdutil -s error: \(error)")
            return true
        }
    }

    private func disableIndexing(path: String) -> Bool {
        // mdutil -i off only accepts the /Volumes/X form, not the firmlink target.
        // Convert back from /System/Volumes/Data/Volumes/X if needed.
        let volumesPath: String
        if path.hasPrefix("/System/Volumes/Data/Volumes/") {
            volumesPath = String(path.dropFirst("/System/Volumes/Data".count))
        } else {
            volumesPath = path
        }
        print("[SpotlightOff] Using path for mdutil: \(volumesPath)")

        // First try running mdutil directly without admin — works if app has disk access
        if runMdutil(path: volumesPath) { return true }

        // Fall back to osascript with administrator privileges
        return runMdutilAsAdmin(path: volumesPath)
    }

    private func runMdutil(path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        p.arguments = ["-i", "off", path]
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do {
            try p.run(); p.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("[SpotlightOff] mdutil direct out: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            print("[SpotlightOff] mdutil direct err: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            print("[SpotlightOff] mdutil direct exit: \(p.terminationStatus)")
            let combined = (out + err).lowercased()
            return p.terminationStatus == 0 && !combined.contains("error") && !combined.contains("could not")
        } catch {
            print("[SpotlightOff] mdutil direct threw: \(error)")
            return false
        }
    }

    private func runMdutilAsAdmin(path: String) -> Bool {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script (\"/usr/bin/mdutil -i off \" & quoted form of \"\(escaped)\") with administrator privileges"
        print("[SpotlightOff] Trying osascript admin for: \(path)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do {
            try p.run(); p.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("[SpotlightOff] osascript out: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            print("[SpotlightOff] osascript err: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            print("[SpotlightOff] osascript exit: \(p.terminationStatus)")
            let combined = (out + err).lowercased()
            return p.terminationStatus == 0 && !combined.contains("error") && !combined.contains("could not")
        } catch {
            print("[SpotlightOff] osascript threw: \(error)")
            return false
        }
    }

    // MARK: History

    private func addToHistory(name: String, path: String) {
        history.removeAll { $0.path == path }
        history.insert(DriveEntry(name: name, path: path), at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        saveHistory()
        onHistoryChanged?()
    }

    func removeEntries(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        saveHistory()
        onHistoryChanged?()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
        onHistoryChanged?()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func loadHistory() {
        guard let data    = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([DriveEntry].self, from: data)
        else { return }
        history = decoded
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var monitor: DriveMonitor
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spotlight Off")
                        .font(.headline)
                    Text("Automatically disables Spotlight indexing on external drives")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Settings
            VStack(alignment: .leading, spacing: 10) {
                Text("SETTINGS")
                    .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        } catch {
                            print("[SpotlightOff] Launch at login error: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            .padding()

            Divider()

            // History header
            HStack {
                Text("PROCESSED DRIVES")
                    .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                Spacer()
                if !monitor.history.isEmpty {
                    Button("Clear All") { monitor.clearHistory() }
                        .foregroundColor(.red)
                        .buttonStyle(.borderless)
                        .font(.caption).fontWeight(.semibold)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // History list
            if monitor.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No drives processed yet")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                    Text("Connect an external drive and Spotlight Off\nwill disable indexing automatically.")
                        .foregroundColor(.secondary.opacity(0.7))
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                List {
                    ForEach(monitor.history) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .fontWeight(.medium)
                                Text(entry.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(dateFormatter.string(from: entry.date))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in monitor.removeEntries(at: offsets) }
                }
                .frame(height: 220)

                Text("Select an entry and press Delete to remove it, or use Clear All.")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()

            Text("Administrator approval is required the first time a drive is processed.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
        }
        .frame(width: 440)
    }
}