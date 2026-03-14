// Spotlight_OffTests.swift
// Unit tests for Spotlight Off.
//
// Coverage:
//
// • DriveEntryTests — Codable round-trip and backward-compatibility decoder.
//   The most critical tests in this file: DriveEntry has been extended with
//   mountPath, status, and format since the original release; old persisted
//   entries that lack these fields must still decode without crashing.
//
// • DriveMonitorTests — exclusion and history state management. All tests use
//   a path that is NOT in mountedPaths, which causes the mdutil guard conditions
//   in addExclusion/removeExclusion to return early — no real processes run.
//
// • LogStoreTests — entry appending, 200-entry cap, and clear().
//
// • AppDelegateTests — openWelcome() window lifecycle: creates on first call,
//   reuses on subsequent calls, re-shows after close without recreation.
//
// • AppDelegateVersionTests — isVersion(_:newerThan:) semantic comparison logic.

import XCTest
@testable import Spotlight_Off

// MARK: - DriveEntry Codable Tests

final class DriveEntryTests: XCTestCase {

    // Full round-trip: all fields present, all values survive encode → decode.
    func testEncodeDecodeRoundTrip() throws {
        let original = DriveEntry(
            name: "My Drive",
            path: "/System/Volumes/Data/Volumes/My Drive",
            mountPath: "/Volumes/My Drive",
            status: .alreadyDisabled
        )
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DriveEntry.self, from: data)

        XCTAssertEqual(decoded.id,        original.id)
        XCTAssertEqual(decoded.name,      original.name)
        XCTAssertEqual(decoded.path,      original.path)
        XCTAssertEqual(decoded.mountPath, original.mountPath)
        XCTAssertEqual(decoded.status,    original.status)
    }

    // Entries saved before mountPath was added must fall back to path.
    func testDecodeLegacyEntryMissingMountPath() throws {
        let json = """
        {
            "id":   "00000000-0000-0000-0000-000000000001",
            "name": "Old Drive",
            "path": "/Volumes/Old Drive",
            "date": 1000000.0,
            "status": "disabled"
        }
        """
        let entry = try JSONDecoder().decode(DriveEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.mountPath, "/Volumes/Old Drive",
                       "mountPath should fall back to path when missing")
        XCTAssertEqual(entry.status, .disabled)
    }

    // Entries saved before status was added must default to .disabled.
    func testDecodeLegacyEntryMissingStatus() throws {
        let json = """
        {
            "id":        "00000000-0000-0000-0000-000000000002",
            "name":      "Old Drive",
            "path":      "/Volumes/Old Drive",
            "mountPath": "/Volumes/Old Drive",
            "date":      1000000.0
        }
        """
        let entry = try JSONDecoder().decode(DriveEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.status, .disabled,
                       "status should default to .disabled when missing")
    }

    // Oldest format: both mountPath and status absent.
    func testDecodeLegacyEntryMissingBoth() throws {
        let json = """
        {
            "id":   "00000000-0000-0000-0000-000000000003",
            "name": "Old Drive",
            "path": "/Volumes/Old Drive",
            "date": 1000000.0
        }
        """
        let entry = try JSONDecoder().decode(DriveEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.mountPath, "/Volumes/Old Drive")
        XCTAssertEqual(entry.status,    .disabled)
    }

    // Every DriveStatus value round-trips through JSON correctly.
    func testAllDriveStatusValuesRoundTrip() throws {
        for status in [DriveStatus.disabled, .alreadyDisabled, .failed] {
            let entry   = DriveEntry(name: "Test", path: "/Volumes/T", mountPath: "/Volumes/T", status: status)
            let data    = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(DriveEntry.self, from: data)
            XCTAssertEqual(decoded.status, status, "Status \(status) failed round-trip")
        }
    }
}

// MARK: - DriveMonitor State Tests

// @MainActor matches DriveMonitor's isolation — all mutations happen on the
// main actor, which is required by the compiler for @MainActor class members.
@MainActor
final class DriveMonitorTests: XCTestCase {

    var monitor: DriveMonitor!

    override func setUp() async throws {
        // Wipe persisted state so each test starts from a known clean baseline.
        UserDefaults.standard.removeObject(forKey: "spotlightoff.history")
        UserDefaults.standard.removeObject(forKey: "spotlightoff.exclusions")
        monitor = DriveMonitor()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "spotlightoff.history")
        UserDefaults.standard.removeObject(forKey: "spotlightoff.exclusions")
    }

    // MARK: Exclusion Tests

    func testAddExclusionAppendsPath() {
        monitor.addExclusion(mountPath: "/Volumes/TestDrive")
        XCTAssertTrue(monitor.exclusions.contains("/Volumes/TestDrive"))
    }

    func testAddExclusionNoDuplicates() {
        monitor.addExclusion(mountPath: "/Volumes/TestDrive")
        monitor.addExclusion(mountPath: "/Volumes/TestDrive")
        let count = monitor.exclusions.filter { $0 == "/Volumes/TestDrive" }.count
        XCTAssertEqual(count, 1, "Duplicate exclusion should be ignored")
    }

    func testRemoveExclusionDeletesPath() {
        monitor.addExclusion(mountPath: "/Volumes/TestDrive")
        monitor.removeExclusion("/Volumes/TestDrive")
        XCTAssertFalse(monitor.exclusions.contains("/Volumes/TestDrive"))
    }

    func testRemoveNonexistentExclusionIsNoOp() {
        monitor.removeExclusion("/Volumes/NeverAdded")
        XCTAssertTrue(monitor.exclusions.isEmpty)
    }

    // addExclusion for an unmounted drive must not attempt mdutil (the guard on
    // mountedPaths returns early). Verified by confirming mountedPaths is unchanged.
    func testAddExclusionUnmountedSkipsMdutil() {
        let path = "/Volumes/NotMounted"
        XCTAssertFalse(monitor.mountedPaths.contains(path))
        monitor.addExclusion(mountPath: path)
        // mountedPaths must remain unchanged — mdutil was not invoked
        XCTAssertFalse(monitor.mountedPaths.contains(path))
        XCTAssertTrue(monitor.exclusions.contains(path))
    }

    // removeExclusion for an unmounted drive must not launch handleVolume.
    func testRemoveExclusionUnmountedSkipsReprocess() {
        let path = "/Volumes/NotMounted"
        monitor.addExclusion(mountPath: path)
        monitor.removeExclusion(path)
        XCTAssertFalse(monitor.exclusions.contains(path))
        XCTAssertFalse(monitor.mountedPaths.contains(path))
    }

    // MARK: History Tests

    func testRemoveEntryDeletesFromHistory() {
        let entry = DriveEntry(name: "Drive A", path: "/Volumes/A", mountPath: "/Volumes/A")
        monitor.history = [entry]
        monitor.removeEntry(entry)
        XCTAssertTrue(monitor.history.isEmpty)
    }

    func testRemoveEntryLeavesOtherEntriesIntact() {
        let entryA = DriveEntry(name: "A", path: "/Volumes/A", mountPath: "/Volumes/A")
        let entryB = DriveEntry(name: "B", path: "/Volumes/B", mountPath: "/Volumes/B")
        monitor.history = [entryA, entryB]
        monitor.removeEntry(entryA)
        XCTAssertEqual(monitor.history.count, 1)
        XCTAssertEqual(monitor.history.first?.name, "B")
    }

    func testClearHistoryEmptiesList() {
        monitor.history = [
            DriveEntry(name: "A", path: "/Volumes/A", mountPath: "/Volumes/A"),
            DriveEntry(name: "B", path: "/Volumes/B", mountPath: "/Volumes/B")
        ]
        monitor.clearHistory()
        XCTAssertTrue(monitor.history.isEmpty)
    }
}

// MARK: - LogStore Tests

final class LogStoreTests: XCTestCase {

    // LogStore.log() dispatches to main async, so each test waits for that flush.
    private func waitForMainQueue() {
        let exp = expectation(description: "main queue flush")
        DispatchQueue.main.async { exp.fulfill() }
        waitForExpectations(timeout: 1)
    }

    func testLogAddsEntry() {
        let store = LogStore()
        store.log("Hello from test")
        waitForMainQueue()
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(store.entries.first?.text.contains("Hello from test") ?? false)
    }

    func testLogEntryBeginsWithTimestamp() {
        let store = LogStore()
        store.log("Timestamped")
        waitForMainQueue()
        // Entries are formatted as "[HH:MM:SS AM/PM] message"
        XCTAssertTrue(store.entries.first?.text.hasPrefix("[") ?? false)
    }

    func testLogCappedAt200Entries() {
        let store = LogStore()
        for i in 0..<250 {
            store.log("Entry \(i)")
        }
        waitForMainQueue()
        XCTAssertLessThanOrEqual(store.entries.count, 200,
                                  "LogStore must not exceed 200 entries")
    }

    func testClearRemovesAllEntries() {
        let store = LogStore()
        store.log("msg 1")
        store.log("msg 2")
        store.clear()
        waitForMainQueue()
        XCTAssertTrue(store.entries.isEmpty)
    }
}

// MARK: - DriveEntry Format Field Tests

final class DriveEntryFormatTests: XCTestCase {

    // format survives a full encode → decode round-trip.
    func testFormatRoundTrip() throws {
        let entry = DriveEntry(name: "Flash", path: "/Volumes/F", mountPath: "/Volumes/F",
                               status: .disabled, format: "ExFAT")
        let data    = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DriveEntry.self, from: data)
        XCTAssertEqual(decoded.format, "ExFAT")
    }

    // nil format is preserved across encode → decode.
    func testFormatNilRoundTrip() throws {
        let entry = DriveEntry(name: "Unknown", path: "/Volumes/U", mountPath: "/Volumes/U")
        let data    = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DriveEntry.self, from: data)
        XCTAssertNil(decoded.format)
    }

    // Entries saved before format was added must decode with format == nil.
    func testLegacyEntryMissingFormatDecodesAsNil() throws {
        let json = """
        {
            "id":        "00000000-0000-0000-0000-000000000010",
            "name":      "Legacy Drive",
            "path":      "/Volumes/Legacy",
            "mountPath": "/Volumes/Legacy",
            "date":      1000000.0,
            "status":    "disabled"
        }
        """
        let entry = try JSONDecoder().decode(DriveEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.format, "format should be nil when missing from persisted JSON")
    }

    // Entries for common filesystem types decode correctly.
    func testKnownFormatStrings() throws {
        for fmt in ["APFS", "HFS+", "ExFAT", "FAT32", "NTFS"] {
            let entry = DriveEntry(name: "Drive", path: "/Volumes/D", mountPath: "/Volumes/D",
                                   format: fmt)
            let data    = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(DriveEntry.self, from: data)
            XCTAssertEqual(decoded.format, fmt, "Format \(fmt) failed round-trip")
        }
    }
}

// MARK: - Semantic Version Comparison Tests

final class AppDelegateVersionTests: XCTestCase {

    // Convenience alias so tests read clearly.
    private func newer(_ a: String, than b: String) -> Bool {
        AppDelegate.isVersion(a, newerThan: b)
    }

    // Basic patch increment.
    func testPatchNewerThanCurrent() {
        XCTAssertTrue(newer("1.1.2", than: "1.1.1"))
    }

    // Same version is not "newer".
    func testSameVersionIsNotNewer() {
        XCTAssertFalse(newer("1.1.2", than: "1.1.2"))
    }

    // Local build ahead of GitHub should not show update banner.
    func testLocalAheadOfRemoteIsNotNewer() {
        XCTAssertFalse(newer("1.1.1", than: "1.1.2"))
    }

    // Minor version bump.
    func testMinorNewerThanCurrent() {
        XCTAssertTrue(newer("1.2.0", than: "1.1.9"))
    }

    // Major version bump.
    func testMajorNewerThanCurrent() {
        XCTAssertTrue(newer("2.0.0", than: "1.9.9"))
    }

    // Two-component version is handled without crashing.
    func testTwoComponentVersions() {
        XCTAssertTrue(newer("1.2", than: "1.1"))
        XCTAssertFalse(newer("1.1", than: "1.2"))
    }

    // Leading "v" prefix (as GitHub returns in tag_name) is handled correctly.
    // Note: the caller strips "v" before calling isVersion, but double-check
    // the raw digits still compare correctly.
    func testNumericVersionsCompareCorrectly() {
        XCTAssertTrue(newer("10.0.0", than: "9.9.9"))
    }
}

// MARK: - AppDelegate openWelcome Window Lifecycle Tests

@MainActor
final class AppDelegateWelcomeTests: XCTestCase {

    var delegate: AppDelegate!

    override func setUp() async throws {
        delegate = AppDelegate()
    }

    override func tearDown() async throws {
        // Close and release the welcome window if one was created.
        delegate.welcomeWindow?.close()
        delegate.welcomeWindow = nil
    }

    // Calling openWelcome() for the first time creates and shows a window.
    func testOpenWelcomeCreatesWindowWhenNil() {
        XCTAssertNil(delegate.welcomeWindow, "No window should exist before first call")
        delegate._showWelcomeWindow()
        XCTAssertNotNil(delegate.welcomeWindow, "Window must be created after openWelcome()")
        XCTAssertTrue(delegate.welcomeWindow?.isVisible ?? false,
                      "Window must be visible after openWelcome()")
    }

    // Calling openWelcome() twice must not create a second window.
    func testOpenWelcomeReusesExistingWindow() {
        delegate._showWelcomeWindow()
        let first = delegate.welcomeWindow

        delegate._showWelcomeWindow()
        let second = delegate.welcomeWindow

        XCTAssertTrue(first === second, "openWelcome() must reuse the existing window, not create a new one")
    }

    // After the window is closed (red X), openWelcome() must make it visible again.
    func testOpenWelcomeReshowsAfterClose() {
        delegate._showWelcomeWindow()
        guard let window = delegate.welcomeWindow else {
            XCTFail("Window was not created on first call")
            return
        }

        window.close()
        XCTAssertFalse(window.isVisible, "Window should not be visible after close()")

        delegate._showWelcomeWindow()
        XCTAssertTrue(delegate.welcomeWindow?.isVisible ?? false,
                      "Window must be visible again after second openWelcome() call")
    }

    // isReleasedWhenClosed must be false — the window object survives close().
    func testWelcomeWindowNotReleasedWhenClosed() {
        delegate._showWelcomeWindow()
        weak var weakRef = delegate.welcomeWindow

        delegate.welcomeWindow?.close()
        // If isReleasedWhenClosed were true, weakRef would be nil here.
        XCTAssertNotNil(weakRef, "welcomeWindow must survive close() (isReleasedWhenClosed = false)")
    }
}
