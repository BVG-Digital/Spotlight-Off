// DriveMonitor.swift
// Volume monitoring and Spotlight disable logic.
//
// Diverges from upstream (titleunknown/Spotlight-Off) in the following ways:
//
// • @MainActor isolation replaces the upstream's manual DispatchQueue.main.async
//   pattern. All @Published mutations are automatically on the main thread.
//   The compiler enforces this, so threading bugs that existed silently in the
//   upstream are caught at build time here.
//
// • Process methods (isIndexingEnabled, disableIndexing, runMdutil,
//   runMdutilAsAdmin, makeProcess, readOutput, run, resolvedPath, volumesPath)
//   are marked nonisolated so they can be called from Task.detached without
//   leaving the actor. This is required once DriveMonitor is @MainActor.
//
// • Task.detached(priority: .utility) replaces DispatchQueue.global(qos: .utility)
//   and Task.sleep replaces DispatchQueue.asyncAfter — keeping all concurrency
//   in Swift's structured concurrency system rather than mixing GCD and async/await.
//
// • osascript is called using the "on run argv" form rather than string
//   interpolation, preventing AppleScript injection from drive names with
//   special characters (a security fix over upstream).
//
// • Process execution has a configurable timeout via DispatchSemaphore so a
//   hung mdutil or osascript call doesn't block the utility thread indefinitely.
//
// • mountPath is tracked separately from path (firmlink-resolved). The mount
//   path (/Volumes/X) is needed for exclusion checks and deduplication; the
//   resolved path (/System/Volumes/Data/Volumes/X) is needed for mdutil -s.
//
// • mountedPaths.insert is now called before the exclusion guard in volumeMounted
//   so excluded drives are still tracked as connected. This lets the menu bar
//   display excluded drives and offer to remove their exclusion directly.
//
// • Drive exclusions: users can right-click a processed drive to prevent it
//   from being processed in future sessions. Persisted in UserDefaults.
//
// • addExclusion re-enables Spotlight on currently-mounted drives, reversing
//   the previous disable so the exclusion takes immediate effect without a
//   remount. This makes "exclude" a true undo of what the app did.
//
// • removeExclusion re-processes currently-mounted drives (re-disables Spotlight)
//   so removing an exclusion takes immediate effect as well, creating symmetric
//   and fully reversible behaviour.
//
// • Failed disable attempts are now recorded in history with DriveStatus.failed
//   so they are visible in the Drives tab rather than only in the Log.
//
// • inFlight deduplication prevents double-processing if a volume fires
//   multiple mount notifications in quick succession.
//
// • sendNotification delivers a UNUserNotification on success or failure,
//   replacing the upstream's silent-on-failure behaviour.

import AppKit
import SwiftUI
import UserNotifications

@MainActor
class DriveMonitor: ObservableObject {
    @Published var history:      [DriveEntry] = []
    @Published var exclusions:   [String]     = []   // /Volumes/X paths to never process
    @Published var mountedPaths: Set<String>  = []   // currently mounted volume paths

    // MARK: - Private state

    /// UserDefaults keys — kept here so magic strings never appear inline.
    private enum Keys {
        static let history    = "spotlightoff.history"
        static let exclusions = "spotlightoff.exclusions"
    }

    private var isStarted = false

    // inFlight tracks mount paths currently being processed.
    // Safe to mutate without locks: DriveMonitor is @MainActor, so all
    // insertions and removals happen on the main thread by definition.
    private var inFlight: Set<String> = []

    // MARK: - Lifecycle

    init() {
        loadHistory()
        loadExclusions()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeMounted(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeUnmounted(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    /// Processes volumes already mounted when the app launches.
    /// Handles drives that were connected before the app started or after a restart.
    func scanMountedVolumes() {
        let keys: [URLResourceKey] = [
            .volumeIsRootFileSystemKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []
        ) ?? []

        // Seed mountedPaths with every currently mounted external volume so
        // the menu bar correctly shows drives that were already connected at launch.
        mountedPaths = Set(urls.filter { isExternalVolume($0) }.map { $0.path })

        LogStore.shared.log("Startup scan: \(urls.count) volume\(urls.count == 1 ? "" : "s") detected \u{2014} checking for external drives\u{2026}")

        var queued = 0
        for url in urls {
            guard isExternalVolume(url) else { continue }
            let mountPath = url.path
            let name      = Self.volumeName(for: url)
            guard !exclusions.contains(mountPath) else {
                LogStore.shared.log("Skipping \u{201C}\(name)\u{201D} \u{2014} drive is on the exclusion list.")
                continue
            }
            guard !inFlight.contains(mountPath) else { continue }
            inFlight.insert(mountPath)
            let deep = resolvedPath(for: mountPath)
            LogStore.shared.log("External drive \u{201C}\(name)\u{201D} detected \u{2014} queuing for processing\u{2026}")
            queued += 1
            Task.detached(priority: .utility) { [weak self] in
                await self?.handleVolume(path: deep, name: name, mountPath: mountPath)
            }
        }

        if queued == 0 {
            LogStore.shared.log("Startup scan complete \u{2014} no external drives detected.")
        } else {
            LogStore.shared.log("Startup scan complete \u{2014} \(queued) external drive\(queued == 1 ? "" : "s") queued for processing.")
        }
    }

    // MARK: - Volume Helpers

    /// Human-readable name for a volume URL.
    static func volumeName(for url: URL) -> String {
        url.lastPathComponent.isEmpty ? "External Drive" : url.lastPathComponent
    }

    // MARK: - Firmlink Helpers

    // On macOS Big Sur+, /Volumes/X is a firmlink to /System/Volumes/Data/Volumes/X.
    // These are NOT symlinks — realpath() and canonicalPath don't follow firmlinks.

    /// Returns the deep firmlink-resolved path (used for mdutil -s status checks).
    private nonisolated func resolvedPath(for path: String) -> String {
        guard path.hasPrefix("/Volumes/") else { return path }
        let candidate = "/System/Volumes/Data" + path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : path
    }

    /// Returns the /Volumes/X form that mdutil -i off requires.
    private nonisolated func volumesPath(for path: String) -> String {
        guard path.hasPrefix("/System/Volumes/Data/Volumes/") else { return path }
        return String(path.dropFirst("/System/Volumes/Data".count))
    }

    // MARK: - Process Helpers

    /// Creates a Process pre-wired with stdout and stderr pipes.
    private nonisolated func makeProcess(
        _ executable: String,
        arguments: [String]
    ) -> (p: Process, out: Pipe, err: Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments     = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError  = err
        return (p, out, err)
    }

    /// Reads all available data from a pipe as a UTF-8 string.
    private nonisolated func readOutput(_ pipe: Pipe) -> String {
        String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Runs a process and waits up to `timeout` seconds.
    /// Uses a semaphore + terminationHandler so a hung process is killed rather than blocking.
    @discardableResult
    private nonisolated func run(_ p: Process, timeout: TimeInterval = 10) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        do { try p.run() } catch {
            LogStore.shared.log("Failed to start process: \(error)")
            return false
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            LogStore.shared.log("\u{26A0}\u{FE0F} Process timed out after \(Int(timeout))s \u{2014} terminated.")
            return false
        }
        return true
    }

    // MARK: - Volume Mounted

    @objc private func volumeMounted(_ notification: NSNotification) {
        guard let mountPath = notification.userInfo?["NSDevicePath"] as? String else { return }
        LogStore.shared.log("Drive mounted: \(mountPath)")

        let url  = URL(fileURLWithPath: mountPath)
        let name = Self.volumeName(for: url)

        guard isExternalVolume(url) else {
            LogStore.shared.log("Skipping \u{201C}\(name)\u{201D} \u{2014} internal or system volume.")
            return
        }

        // Track ALL mounted external drives before the exclusion check so the
        // menu bar can display excluded drives and offer to remove their exclusion.
        mountedPaths.insert(mountPath)

        guard !exclusions.contains(mountPath) else {
            LogStore.shared.log("Skipping \u{201C}\(name)\u{201D} \u{2014} drive is on the exclusion list.")
            return
        }
        guard !inFlight.contains(mountPath) else {
            LogStore.shared.log("Skipping \u{201C}\(name)\u{201D} \u{2014} processing already in progress.")
            return
        }

        inFlight.insert(mountPath)
        let deep = resolvedPath(for: mountPath)
        LogStore.shared.log("External drive connected: \u{201C}\(name)\u{201D} \u{2014} disabling Spotlight indexing\u{2026}")

        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 s mount settling delay
            await self?.handleVolume(path: deep, name: name, mountPath: mountPath)
        }
    }

    @objc private func volumeUnmounted(_ notification: NSNotification) {
        guard let mountPath = notification.userInfo?["NSDevicePath"] as? String else { return }
        mountedPaths.remove(mountPath)
        LogStore.shared.log("Drive ejected: \(mountPath)")
    }

    // MARK: - Volume Filtering
    // Accepts any local, non-internal, non-root volume.
    // volumeIsRemovable is intentionally not checked — many bus-powered and
    // SSD external drives don't set that flag.

    private func isExternalVolume(_ url: URL) -> Bool {
        guard let vals = try? url.resourceValues(forKeys: [
            .volumeIsRootFileSystemKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey
        ]) else {
            LogStore.shared.log("Unable to read volume properties for \(url.path) \u{2014} skipping.")
            return false
        }

        let isRoot     = vals.volumeIsRootFileSystem ?? false
        let isInternal = vals.volumeIsInternal       ?? true   // unknown = treat as internal
        let isLocal    = vals.volumeIsLocal           ?? false

        if isRoot     { return false }
        if isInternal { return false }
        if !isLocal   { return false }
        return true
    }

    // MARK: - Spotlight Check & Disable

    private func handleVolume(path: String, name: String, mountPath: String) async {
        // Always remove from in-flight when done — we're on MainActor so no dispatch needed.
        defer { inFlight.remove(mountPath) }

        // Run the blocking process calls off the main thread.
        let enabled = await Task.detached(priority: .utility) { self.isIndexingEnabled(path: path) }.value
        LogStore.shared.log("Spotlight indexing on \u{201C}\(name)\u{201D}: \(enabled ? "enabled" : "disabled")")

        guard enabled else {
            // Spotlight was already disabled — no action needed, but still record
            // the drive so the Drives tab reflects all verified-disabled drives.
            LogStore.shared.log("Spotlight indexing already disabled on \u{201C}\(name)\u{201D} \u{2014} no action required.")
            addToHistory(name: name, path: path, mountPath: mountPath, status: .alreadyDisabled)
            return
        }

        let ok = await Task.detached(priority: .utility) { self.disableIndexing(path: path) }.value
        LogStore.shared.log("Spotlight indexing \(ok ? "successfully disabled" : "could not be disabled") on \u{201C}\(name)\u{201D}.")

        // Record the outcome regardless of success — failed attempts appear in the
        // Drives tab with a red indicator so the user knows action is needed.
        addToHistory(name: name, path: path, mountPath: mountPath, status: ok ? .disabled : .failed)

        if ok {
            AppState.shared.iconName = "externaldrive.badge.checkmark"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                AppState.shared.iconName = "externaldrive.badge.xmark"
            }
        }
        sendNotification(driveName: name, succeeded: ok)
    }

    private func sendNotification(driveName: String, succeeded: Bool) {
        // Sanitize: strip invisible/control code points and cap length.
        let safeName = String(
            driveName
                .unicodeScalars
                .filter { !$0.properties.isDefaultIgnorableCodePoint }
                .prefix(50)
                .map(Character.init)
        )
        let content = UNMutableNotificationContent()
        if succeeded {
            content.title = "Spotlight Indexing Disabled"
            content.body  = "\u{201C}\(safeName)\u{201D} will no longer be indexed by Spotlight."
        } else {
            content.title = "Spotlight Off \u{2014} Action Required"
            content.body  = "Could not disable indexing on \u{201C}\(safeName)\u{201D}. Open History & Settings for details."
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private nonisolated func isIndexingEnabled(path: String) -> Bool {
        let (p, out, err) = makeProcess("/usr/bin/mdutil", arguments: ["-s", path])
        guard run(p) else {
            LogStore.shared.log("mdutil status check failed \u{2014} assuming indexing is enabled.")
            return true   // fail open: attempt disable anyway
        }
        let combined = readOutput(out) + readOutput(err)
        let trimmed  = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        LogStore.shared.log("mdutil -s: \(trimmed)")
        // kMDConfigSearchLevelTransitioning means Spotlight is still initialising
        // on a freshly mounted drive. Treat as enabled and proceed to disable.
        if trimmed.lowercased().contains("transitioning") {
            LogStore.shared.log("Spotlight indexing is initialising \u{2014} proceeding with disable attempt.")
        }
        return !trimmed.lowercased().contains("disabled")
    }

    private nonisolated func disableIndexing(path: String) -> Bool {
        let vPath = volumesPath(for: path)
        LogStore.shared.log("Using path for mdutil: \(vPath)")

        // First try running mdutil directly — works if Full Disk Access is granted.
        if runMdutil(path: vPath) { return true }

        // Fall back to osascript with administrator privileges.
        return runMdutilAsAdmin(path: vPath)
    }

    /// Re-enables Spotlight indexing on a drive. Called when a drive is excluded
    /// while currently mounted, reversing the previous disable.
    private nonisolated func enableIndexing(path: String) -> Bool {
        let vPath = volumesPath(for: path)
        LogStore.shared.log("Using path for mdutil: \(vPath)")
        let (p, out, err) = makeProcess("/usr/bin/mdutil", arguments: ["-i", "on", vPath])
        guard run(p) else { return false }
        LogStore.shared.log("mdutil out: \(readOutput(out).trimmingCharacters(in: .whitespacesAndNewlines))")
        LogStore.shared.log("mdutil err: \(readOutput(err).trimmingCharacters(in: .whitespacesAndNewlines))")
        LogStore.shared.log("mdutil exit: \(p.terminationStatus)")
        return p.terminationStatus == 0
    }

    private nonisolated func runMdutil(path: String) -> Bool {
        let (p, out, err) = makeProcess("/usr/bin/mdutil", arguments: ["-i", "off", path])
        guard run(p) else { return false }
        LogStore.shared.log("mdutil out: \(readOutput(out).trimmingCharacters(in: .whitespacesAndNewlines))")
        LogStore.shared.log("mdutil err: \(readOutput(err).trimmingCharacters(in: .whitespacesAndNewlines))")
        LogStore.shared.log("mdutil exit: \(p.terminationStatus)")
        // Exit code is the authoritative signal — stdout/stderr are for diagnostics only.
        return p.terminationStatus == 0
    }

    private nonisolated func runMdutilAsAdmin(path: String) -> Bool {
        LogStore.shared.log("Requesting administrator privileges to disable indexing on \(path)\u{2026}")
        // Pass the path as a script argument rather than interpolating it into the
        // script string — this prevents AppleScript injection from special characters.
        let (p, out, err) = makeProcess("/usr/bin/osascript", arguments: [
            "-e", "on run argv",
            "-e", "do shell script \"/usr/bin/mdutil -i off \" & quoted form of (item 1 of argv) with administrator privileges",
            "-e", "end run",
            "--", path
        ])
        // 5-minute timeout — the user may take time to respond to the admin dialog.
        guard run(p, timeout: 300) else { return false }
        LogStore.shared.log("osascript out: \(readOutput(out).trimmingCharacters(in: .whitespacesAndNewlines))")
        LogStore.shared.log("osascript err: \(readOutput(err).trimmingCharacters(in: .whitespacesAndNewlines))")
        LogStore.shared.log("osascript exit: \(p.terminationStatus)")
        return p.terminationStatus == 0
    }

    // MARK: - History

    private func addToHistory(name: String, path: String, mountPath: String, status: DriveStatus = .disabled) {
        history.removeAll { $0.path == path }
        history.insert(DriveEntry(name: name, path: path, mountPath: mountPath, status: status), at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        saveHistory()
    }

    func removeEntry(_ entry: DriveEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func removeEntries(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Keys.history)
        }
    }

    private func loadHistory() {
        guard let data    = UserDefaults.standard.data(forKey: Keys.history),
              let decoded = try? JSONDecoder().decode([DriveEntry].self, from: data)
        else { return }
        history = decoded
    }

    // MARK: - Exclusions

    func addExclusion(mountPath: String) {
        guard !exclusions.contains(mountPath) else { return }
        exclusions.append(mountPath)
        saveExclusions()
        LogStore.shared.log("Drive added to exclusion list: \(mountPath)")

        // If the drive is currently mounted, re-enable Spotlight immediately.
        // "Exclude" is a true undo: we reverse the disable we already applied
        // so the user gets Spotlight back right now, not just on future mounts.
        guard mountedPaths.contains(mountPath) else { return }
        let name = Self.volumeName(for: URL(fileURLWithPath: mountPath))
        let deep = resolvedPath(for: mountPath)
        LogStore.shared.log("Re-enabling Spotlight indexing on \u{201C}\(name)\u{201D} \u{2014} reversing previous disable\u{2026}")
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let ok = self.enableIndexing(path: deep)
            LogStore.shared.log("Spotlight indexing \(ok ? "successfully re-enabled" : "could not be re-enabled") on \u{201C}\(name)\u{201D}.")
        }
    }

    func removeExclusion(_ path: String) {
        exclusions.removeAll { $0 == path }
        saveExclusions()
        LogStore.shared.log("Drive removed from exclusion list: \(path)")

        // If the drive is currently mounted, process it immediately — equivalent
        // to a fresh mount without the exclusion. This means removing an exclusion
        // takes effect right away without requiring a remount.
        guard mountedPaths.contains(path), !inFlight.contains(path) else { return }
        let name = Self.volumeName(for: URL(fileURLWithPath: path))
        let deep = resolvedPath(for: path)
        LogStore.shared.log("External drive \u{201C}\(name)\u{201D} is connected \u{2014} disabling Spotlight indexing\u{2026}")
        inFlight.insert(path)
        Task.detached(priority: .utility) { [weak self] in
            await self?.handleVolume(path: deep, name: name, mountPath: path)
        }
    }

    private func saveExclusions() {
        UserDefaults.standard.set(exclusions, forKey: Keys.exclusions)
    }

    private func loadExclusions() {
        exclusions = UserDefaults.standard.stringArray(forKey: Keys.exclusions) ?? []
    }
}
