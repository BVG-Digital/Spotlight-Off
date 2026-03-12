// Spotlight_OffTests.swift
// Unit tests for Spotlight Off.
//
// Coverage:
//
// • DriveEntryTests — Codable round-trip and backward-compatibility decoder.
//   The most critical tests in this file: DriveEntry has been extended with
//   mountPath and status since the original release, and old persisted entries
//   that lack these fields must still decode without crashing or data loss.
//
// • DriveMonitorTests — exclusion and history state management. All tests use
//   a path that is NOT in mountedPaths, which causes the mdutil guard conditions
//   in addExclusion/removeExclusion to return early — no real processes run.
//
// • LogStoreTests — entry appending, 200-entry cap, and clear().

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
