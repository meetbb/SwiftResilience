//
//  OfflineQueueEngineTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 07/06/26.
//

import XCTest
@testable import SwiftResilience

// MARK: - Test infrastructure

// Feeds pre-baked responses one by one. Crashes on over-call (intentional).
final class QueueEngineTestSession: NetworkSession, @unchecked Sendable {
    
    struct Entry {
        let data: Data
        let statusCode: Int
    }
    
    private var entries: [Entry]
    private(set) var callCount = 0
    private(set) var receivedRequests: [URLRequest] = []
    
    init(entries: [Entry]) {
        self.entries = entries
    }
    
    convenience init(statusCode: Int = 200, data: Data = Data()) {
        self.init(entries: [Entry(data: data, statusCode: statusCode)])
    }
    
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        receivedRequests.append(request)
        let entry = entries[callCount]
        callCount += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: entry.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (entry.data, response)
    }
}

// Always throws the configured error.
final class AlwaysFailingSession: NetworkSession, @unchecked Sendable {
    let error: Error
    private(set) var callCount = 0
    
    init(error: Error) { self.error = error }
    
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        throw error
    }
}

// Helpers

private func makeTempStore() throws -> (DiskQueueStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("OQE-\(UUID().uuidString)", isDirectory: true)
    return (try DiskQueueStore(directory: dir), dir)
}

private struct SampleQueueable: QueueableRequest {
    var url      = URL(string: "https://api.example.com/posts")!
    var method   = HTTPMethod.post
    var body     = Data("{\"text\":\"hello\"}".utf8)
    var ttl:      TimeInterval  = 86_400
    var priority: QueuePriority = .normal
}

private func makeEntry(
    url: URL = URL(string: "https://api.example.com/posts")!,
    priority: QueuePriority = .normal,
    ttl: TimeInterval = 86_400,
    enqueuedAt: Date = .now
) -> QueueEntry {
    QueueEntry(
        SampleQueueable(ttl: ttl, priority: priority),
        enqueuedAt: enqueuedAt
    )
}

// MARK: - Enqueue: fast path (online)

final class OfflineQueueEngineEnqueueOnlineTests: XCTestCase {
    
    func test_enqueue_online_sendsImmediately_nothingWrittenToDisk() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let session = QueueEngineTestSession(statusCode: 200)
        let monitor = MockReachabilityMonitor(isConnected: true)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        try await engine.enqueue(SampleQueueable())
        
        XCTAssertEqual(session.callCount, 1, "Should have made one network call.")
        let count = await store.count()
        XCTAssertEqual(count, 0, "Nothing should be written to disk on a successful fast path.")
    }
    
    func test_enqueue_online_nonConnectivityError_rethrows_nothingQueued() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let session = QueueEngineTestSession(statusCode: 401)
        let monitor = MockReachabilityMonitor(isConnected: true)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        do {
            try await engine.enqueue(SampleQueueable())
            XCTFail("Expected NetworkError.httpError to be thrown.")
        } catch NetworkError.httpError(let code, _) {
            XCTAssertEqual(code, 401)
        }
        
        let count = await store.count()
        XCTAssertEqual(count, 0, "A 4xx error should not result in a queued entry.")
    }
    
    func test_enqueue_online_connectivityError_writesToDisk() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let session = AlwaysFailingSession(error: URLError(.notConnectedToInternet))
        let monitor = MockReachabilityMonitor(isConnected: true)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        try await engine.enqueue(SampleQueueable())
        
        // The fast-path attempt failed with .noConnection — must fall through to disk.
        let count = await store.count()
        XCTAssertEqual(count, 1)
    }
}

// MARK: - Enqueue: offline path

final class OfflineQueueEngineEnqueueOfflineTests: XCTestCase {
    
    func test_enqueue_offline_writesToDisk_noNetworkCall() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let session = QueueEngineTestSession(statusCode: 200)
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        try await engine.enqueue(SampleQueueable())
        
        XCTAssertEqual(session.callCount, 0, "No network call should be made when offline.")
        let count = await store.count()
        XCTAssertEqual(count, 1, "Request should be persisted to disk.")
    }
    
    func test_enqueue_offline_preservesRequestFields() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let request = SampleQueueable(
            url: URL(string: "https://api.example.com/comments")!,
            method: .put,
            body: Data("{\"id\":42}".utf8),
            ttl: 7_200,
            priority: .high
        )
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: QueueEngineTestSession()),
            reachabilityMonitor: monitor,
            store: store
        )
        
        try await engine.enqueue(request)
        
        let entries = await store.load()
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.url,      request.url)
        XCTAssertEqual(entry.method,   request.method.rawValue)
        XCTAssertEqual(entry.body,     request.body)
        XCTAssertEqual(entry.ttl,      request.ttl)
        XCTAssertEqual(entry.priority, request.priority.rawValue)
    }
}

// MARK: - maxQueueSize

final class OfflineQueueEngineSizeCapTests: XCTestCase {
    
    func test_enqueue_exceedingMaxQueueSize_throwsFull() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: QueueEngineTestSession()),
            reachabilityMonitor: monitor,
            store: store,
            maxQueueSize: 2
        )
        
        try await engine.enqueue(SampleQueueable())
        try await engine.enqueue(SampleQueueable())
        
        do {
            try await engine.enqueue(SampleQueueable())
            XCTFail("Expected OfflineQueueError.full")
        } catch OfflineQueueError.full {
            // expected
        }
    }
}

// MARK: - cancel

final class OfflineQueueEngineCancelTests: XCTestCase {
    
    func test_cancel_removesEntryFromDisk() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: QueueEngineTestSession()),
            reachabilityMonitor: monitor,
            store: store
        )
        
        try await engine.enqueue(SampleQueueable())
        let entries = await store.load()
        let id = entries[0].id
        
        await engine.cancel(id: id)
        
        let count = await store.count()
        XCTAssertEqual(count, 0)
    }
    
    func test_cancel_nonExistentID_isNoOp() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: QueueEngineTestSession()),
            reachabilityMonitor: monitor,
            store: store
        )
        
        // Should not throw or crash.
        await engine.cancel(id: UUID())
    }
}

// MARK: - Drain cycle

final class OfflineQueueEngineDrainCycleTests: XCTestCase {
    
    func test_drainCycle_sendsQueuedEntry_deletesOnSuccess() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let session = QueueEngineTestSession(statusCode: 200)
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        // Pre-populate the queue (bypassing enqueue, which would check connectivity).
        let entry = makeEntry()
        try await store.save(entry)
        
        await engine.runDrainCycle()
        
        XCTAssertEqual(session.callCount, 1)
        let count = await store.count()
        XCTAssertEqual(count, 0, "Successfully sent entry must be deleted.")
    }
    
    func test_drainCycle_expiredEntry_deletedWithoutSend() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let session = QueueEngineTestSession(statusCode: 200)
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        let expired = makeEntry(ttl: 1, enqueuedAt: Date.now.addingTimeInterval(-60))
        try await store.save(expired)
        
        await engine.runDrainCycle()
        
        XCTAssertEqual(session.callCount, 0, "Expired entries must not be sent.")
        let count = await store.count()
        XCTAssertEqual(count, 0, "Expired entries must be deleted from disk.")
    }
    
    func test_drainCycle_connectivityError_leavesEntryOnDisk() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let session = AlwaysFailingSession(error: URLError(.notConnectedToInternet))
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        let entry = makeEntry()
        try await store.save(entry)
        
        await engine.runDrainCycle()
        
        // Network is still down — entry must stay for the next reconnect.
        let count = await store.count()
        XCTAssertEqual(count, 1)
    }
    
    func test_drainCycle_serverError_deletesEntry() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let session = QueueEngineTestSession(statusCode: 422)
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        let entry = makeEntry()
        try await store.save(entry)
        
        await engine.runDrainCycle()
        
        // 422 = unprocessable entity — retrying won't help. Entry should be removed.
        let count = await store.count()
        XCTAssertEqual(count, 0)
    }
    
    func test_drainCycle_injectsIdempotencyKeyHeader() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let session = QueueEngineTestSession(statusCode: 200)
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        let request = SampleQueueable()
        let entry   = QueueEntry(request)
        try await store.save(entry)
        
        await engine.runDrainCycle()
        
        let sentRequest = session.receivedRequests.first
        XCTAssertNotNil(sentRequest?.value(forHTTPHeaderField: "Idempotency-Key"),
                        "Idempotency-Key header must be present on replayed requests.")
        XCTAssertEqual(
            sentRequest?.value(forHTTPHeaderField: "Idempotency-Key"),
            entry.idempotencyKey
        )
    }
}

// MARK: - Drain ordering

final class OfflineQueueEngineDrainOrderTests: XCTestCase {
    
    func test_drainCycle_sendsHigherPriorityFirst() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let base = Date(timeIntervalSince1970: 1_748_476_800)
        
        // Build a session with enough 200 responses for all entries.
        let entries = Array(repeating: QueueEngineTestSession.Entry(data: Data(), statusCode: 200), count: 3)
        let session = QueueEngineTestSession(entries: entries)
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        let normalURL   = URL(string: "https://api.example.com/normal")!
        let highURL     = URL(string: "https://api.example.com/high")!
        let criticalURL = URL(string: "https://api.example.com/critical")!
        
        // Save in reverse priority order to confirm drain reorders them.
        try await store.save(QueueEntry(SampleQueueable(url: normalURL,   priority: .normal),   enqueuedAt: base))
        try await store.save(QueueEntry(SampleQueueable(url: highURL,     priority: .high),     enqueuedAt: base))
        try await store.save(QueueEntry(SampleQueueable(url: criticalURL, priority: .critical), enqueuedAt: base))
        
        await engine.runDrainCycle()
        
        let sentURLs = session.receivedRequests.compactMap(\.url)
        XCTAssertEqual(sentURLs, [criticalURL, highURL, normalURL])
    }
    
    func test_drainCycle_FIFO_withinSamePriority() async throws {
        let (store, dir) = try makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        
        let base    = Date(timeIntervalSince1970: 1_748_476_800)
        let oldest  = URL(string: "https://api.example.com/oldest")!
        let middle  = URL(string: "https://api.example.com/middle")!
        let newest  = URL(string: "https://api.example.com/newest")!
        
        let entries = Array(repeating: QueueEngineTestSession.Entry(data: Data(), statusCode: 200), count: 3)
        let session = QueueEngineTestSession(entries: entries)
        let monitor = MockReachabilityMonitor(isConnected: false)
        let engine  = OfflineQueueEngine(
            requestEngine: AsyncRequestEngine(session: session),
            reachabilityMonitor: monitor,
            store: store
        )
        
        // Save newest first — drain should still send oldest first.
        try await store.save(QueueEntry(SampleQueueable(url: newest), enqueuedAt: base.addingTimeInterval(20)))
        try await store.save(QueueEntry(SampleQueueable(url: middle), enqueuedAt: base.addingTimeInterval(10)))
        try await store.save(QueueEntry(SampleQueueable(url: oldest), enqueuedAt: base))
        
        await engine.runDrainCycle()
        
        let sentURLs = session.receivedRequests.compactMap(\.url)
        XCTAssertEqual(sentURLs, [oldest, middle, newest])
    }
}
