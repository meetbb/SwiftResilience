//
//  DiskQueueStoreTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 07/06/26.
//

import XCTest
@testable import SwiftResilience

// MARK: - Helpers

private func makeStore() throws -> (DiskQueueStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftResilienceTests-\(UUID().uuidString)", isDirectory: true)
    let store = try DiskQueueStore(directory: dir)
    return (store, dir)
}

private func makeEntry(
    priority: QueuePriority = .normal,
    ttl: TimeInterval = 86_400,
    enqueuedAt: Date = .now,
    id: UUID = UUID()
) -> QueueEntry {
    QueueEntry(
        SampleQueueableRequest(ttl: ttl, priority: priority),
        id: id,
        enqueuedAt: enqueuedAt
    )
}

// Minimal QueueableRequest for store tests.
private struct SampleQueueableRequest: QueueableRequest {
    var url      = URL(string: "https://api.example.com/items")!
    var method   = HTTPMethod.post
    var body     = Data("{\"x\":1}".utf8)
    var ttl:      TimeInterval
    var priority: QueuePriority
}

// MARK: - Directory creation

final class DiskQueueStoreDirectoryTests: XCTestCase {

    func test_init_createsDirectoryIfMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SR-new-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        _ = try DiskQueueStore(directory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func test_init_succeedsWhenDirectoryAlreadyExists() throws {
        let (_, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // Creating a second store pointing at the same directory must not throw.
        XCTAssertNoThrow(try DiskQueueStore(directory: dir))
    }
}

// MARK: - save

final class DiskQueueStoreSaveTests: XCTestCase {

    func test_save_writesFileToDirectory() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let entry = makeEntry()
        try await store.save(entry)

        let expected = dir.appendingPathComponent("\(entry.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func test_save_fileNameMatchesEntryID() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let id    = UUID()
        let entry = makeEntry(id: id)
        try await store.save(entry)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains("\(id.uuidString).json"))
    }

    func test_save_overwritesExistingFile() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        let first  = makeEntry(priority: .normal,   id: id)
        let second = makeEntry(priority: .critical, id: id)

        try await store.save(first)
        try await store.save(second)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, 1, "Save with same ID should overwrite, not create a second file.")
    }

    func test_save_multipleDifferentEntries_createsMultipleFiles() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        try await store.save(makeEntry())
        try await store.save(makeEntry())
        try await store.save(makeEntry())

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, 3)
    }
}

// MARK: - load

final class DiskQueueStoreLoadTests: XCTestCase {

    func test_load_emptyDirectory_returnsEmptyArray() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let entries = await store.load()
        XCTAssertTrue(entries.isEmpty)
    }

    func test_load_returnsPersistedEntry() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let id    = UUID()
        let date  = Date(timeIntervalSince1970: 1_748_476_800)
        let entry = makeEntry(enqueuedAt: date, id: id)
        try await store.save(entry)

        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, id)
    }

    func test_load_doesNotReturnExpiredEntries() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let expired = makeEntry(ttl: 1, enqueuedAt: Date.now.addingTimeInterval(-60))
        let fresh   = makeEntry(ttl: 86_400)
        try await store.save(expired)
        try await store.save(fresh)

        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, fresh.id)
    }

    func test_load_sortsByPriorityDescending() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let base = Date(timeIntervalSince1970: 1_748_476_800)
        let normal   = makeEntry(priority: .normal,   enqueuedAt: base)
        let high     = makeEntry(priority: .high,     enqueuedAt: base)
        let critical = makeEntry(priority: .critical, enqueuedAt: base)

        // Save in reverse order to ensure sort is applied, not insertion order.
        try await store.save(normal)
        try await store.save(high)
        try await store.save(critical)

        let loaded = await store.load()
        XCTAssertEqual(loaded.map(\.id), [critical.id, high.id, normal.id])
    }

    func test_load_sortsByEnqueuedAtAscendingWithinSamePriority() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let base    = Date(timeIntervalSince1970: 1_748_476_800)
        let oldest  = makeEntry(priority: .normal, enqueuedAt: base)
        let middle  = makeEntry(priority: .normal, enqueuedAt: base.addingTimeInterval(10))
        let newest  = makeEntry(priority: .normal, enqueuedAt: base.addingTimeInterval(20))

        // Save newest first to confirm sort overrides insertion order.
        try await store.save(newest)
        try await store.save(middle)
        try await store.save(oldest)

        let loaded = await store.load()
        XCTAssertEqual(loaded.map(\.id), [oldest.id, middle.id, newest.id])
    }

    func test_load_skipsMalformedFiles() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // Write a corrupt file directly.
        let corrupt = dir.appendingPathComponent("corrupt.json")
        try Data("not valid json {{{".utf8).write(to: corrupt)

        // Save one valid entry alongside it.
        let valid = makeEntry()
        try await store.save(valid)

        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, valid.id)
    }

    func test_load_ignoresNonJSONFiles() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // Drop a non-JSON file in the directory.
        let txtFile = dir.appendingPathComponent("readme.txt")
        try Data("hello".utf8).write(to: txtFile)

        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)
    }
}

// MARK: - delete

final class DiskQueueStoreDeleteTests: XCTestCase {

    func test_delete_removesFile() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let entry = makeEntry()
        try await store.save(entry)
        await store.delete(id: entry.id)

        let expected = dir.appendingPathComponent("\(entry.id.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path))
    }

    func test_delete_nonExistentID_doesNotThrow() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // Should silently succeed — safe to call after a successful send.
        await store.delete(id: UUID())
    }

    func test_delete_onlyRemovesTargetEntry() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let toDelete = makeEntry()
        let toKeep   = makeEntry()
        try await store.save(toDelete)
        try await store.save(toKeep)

        await store.delete(id: toDelete.id)

        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, toKeep.id)
    }
}

// MARK: - deleteExpired

final class DiskQueueStoreDeleteExpiredTests: XCTestCase {

    func test_deleteExpired_removesOnlyExpiredFiles() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let expired = makeEntry(ttl: 1,      enqueuedAt: Date.now.addingTimeInterval(-60))
        let fresh   = makeEntry(ttl: 86_400, enqueuedAt: .now)
        try await store.save(expired)
        try await store.save(fresh)

        let deletedCount = await store.deleteExpired()
        XCTAssertEqual(deletedCount, 1)

        let remaining = await store.load()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, fresh.id)
    }

    func test_deleteExpired_returnsZeroWhenNothingExpired() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        try await store.save(makeEntry(ttl: 86_400))
        let count = await store.deleteExpired()
        XCTAssertEqual(count, 0)
    }

    func test_deleteExpired_emptyStore_returnsZero() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let count = await store.deleteExpired()
        XCTAssertEqual(count, 0)
    }
}

// MARK: - count

final class DiskQueueStoreCountTests: XCTestCase {

    func test_count_returnsZeroForEmptyStore() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let n = await store.count()
        XCTAssertEqual(n, 0)
    }

    func test_count_reflectsNumberOfFilesOnDisk() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        try await store.save(makeEntry())
        try await store.save(makeEntry())
        let countAfterTwoSaves = await store.count()
        XCTAssertEqual(countAfterTwoSaves, 2)
    }

    func test_count_includesExpiredEntries() async throws {
        // count() is used for queue-size enforcement before writing,
        // so it must include expired entries that haven't been swept yet.
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let expired = makeEntry(ttl: 1, enqueuedAt: Date.now.addingTimeInterval(-60))
        try await store.save(expired)
        let countWithExpired = await store.count()
        XCTAssertEqual(countWithExpired, 1)
    }

    func test_count_decreasesAfterDelete() async throws {
        let (store, dir) = try makeStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let entry = makeEntry()
        try await store.save(entry)
        let countAfterSave = await store.count()
        XCTAssertEqual(countAfterSave, 1)

        await store.delete(id: entry.id)
        let countAfterDelete = await store.count()
        XCTAssertEqual(countAfterDelete, 0)
    }
}
