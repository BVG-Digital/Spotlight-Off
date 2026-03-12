// Models.swift
// Shared data types and observable state objects.
//
// Diverges from upstream (titleunknown/Spotlight-Off) in the following ways:
//
// • DriveStatus enum records the outcome of each processing attempt:
//   .disabled (app successfully disabled Spotlight), .alreadyDisabled (Spotlight
//   was already off when the drive connected), .failed (attempted but could not
//   disable). Backward-compatible decoder defaults to .disabled for entries saved
//   before this field was added.
//
// • DriveEntry gains a mountPath field (the original /Volumes/X path) alongside
//   the firmlink-resolved path. This separation is required for the exclusions
//   feature — exclusion checks must use the mount path, while mdutil requires
//   the resolved path. A custom Decodable init provides backward compatibility
//   with any entries saved before mountPath was added.
//
// • DriveEntry gains a status: DriveStatus field so the Drives tab can surface
//   per-row outcomes (disabled, already off, or failed) visually.
//
// • LogStore.entries is [LogEntry] rather than [String]. LogEntry carries a
//   stable UUID, which is required for correct ForEach identity and scroll
//   anchoring in the Log tab's LazyVStack.
//
// • AppState is a separate observable for the menu bar icon name. DriveMonitor
//   sets it directly (both are @MainActor) when a drive is processed, without
//   needing a callback closure like the upstream's onHistoryChanged pattern.
//
// • LogStore and AppState are NOT marked @MainActor. Marking them @MainActor
//   causes an isolation error on `static let shared = LogStore()` because the
//   initialiser becomes actor-isolated but the static property is initialised
//   lazily outside an actor context. Instead, log() and clear() marshal to
//   the main thread internally using DispatchQueue.main.async.

import SwiftUI

// MARK: - Drive Status

/// The outcome of Spotlight Off's attempt to process an external drive.
enum DriveStatus: String, Codable {
    /// Spotlight indexing was successfully disabled by this app.
    case disabled
    /// Spotlight indexing was already off when the drive connected — no action was taken.
    case alreadyDisabled
    /// The app attempted to disable Spotlight indexing but could not do so.
    case failed
}

// MARK: - Drive Entry

/// Represents a drive that Spotlight Off has processed or attempted to process.
struct DriveEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: String        // firmlink-resolved path used by mdutil
    let mountPath: String   // original /Volumes/X path used for exclusion checks
    let date: Date
    let status: DriveStatus

    init(name: String, path: String, mountPath: String, status: DriveStatus = .disabled) {
        self.id        = UUID()
        self.name      = name
        self.path      = path
        self.mountPath = mountPath
        self.date      = Date()
        self.status    = status
    }

    // Backward-compatible decoder: entries saved before mountPath or status were added
    // fall back to safe defaults (.disabled for status, path for mountPath).
    init(from decoder: Decoder) throws {
        let c  = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self,   forKey: .id)
        name      = try c.decode(String.self, forKey: .name)
        path      = try c.decode(String.self, forKey: .path)
        mountPath = try c.decodeIfPresent(String.self,      forKey: .mountPath) ?? path
        date      = try c.decode(Date.self,   forKey: .date)
        status    = try c.decodeIfPresent(DriveStatus.self, forKey: .status)    ?? .disabled
    }
}

// MARK: - Log Entry

/// A single timestamped line in the activity log.
struct LogEntry: Identifiable {
    let id   = UUID()
    let text: String
}

// MARK: - Log Store

/// Append-only in-memory activity log, capped at 200 entries.
/// Not actor-isolated — log() marshals to main internally via DispatchQueue.
class LogStore: ObservableObject {
    static let shared = LogStore()
    @Published var entries: [LogEntry] = []

    // DateFormatter is expensive to create — cache it as a static.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    func log(_ message: String) {
        let timestamp = Self.timeFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        print(line)
        DispatchQueue.main.async {
            self.entries.append(LogEntry(text: line))
            if self.entries.count > 200 { self.entries.removeFirst() }
        }
    }

    func clear() {
        DispatchQueue.main.async { self.entries = [] }
    }
}

// MARK: - App State

/// Shared observable used to update the menu bar icon from DriveMonitor
/// without requiring a direct reference to the SwiftUI scene.
/// Always mutated from @MainActor (DriveMonitor), so no extra marshalling needed.
class AppState: ObservableObject {
    static let shared = AppState()
    @Published var iconName = "externaldrive.badge.xmark"
}
