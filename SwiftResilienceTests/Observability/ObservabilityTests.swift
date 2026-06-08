//
//  ObservabilityTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 08/06/26.
//

import XCTest
@testable import SwiftResilience

// MARK: - Test infrastructure

/// Records every `RequestEvent` in arrival order.
/// Actor-isolated so it satisfies `RequestEventSink: Sendable`.
private actor CapturingEventSink: RequestEventSink {
    private(set) var events: [RequestEvent] = []

    func record(_ event: RequestEvent) {
        events.append(event)
    }
}

/// Minimal `NetworkRequest` stub.
private struct StubRequest: NetworkRequest {
    let url: URL
    var method: HTTPMethod = .get
}

/// Returns responses from a pre-baked list. Crashes on over-call (intentional).
private final class MockSession: NetworkSession, @unchecked Sendable {

    struct Entry { let statusCode: Int; let data: Data }

    private var queue: [Entry]
    private(set) var callCount = 0

    init(_ entries: [Entry]) { self.queue = entries }

    convenience init(statusCode: Int, data: Data = Data()) {
        self.init([Entry(statusCode: statusCode, data: data)])
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let entry = queue[callCount]
        callCount += 1
        let response = HTTPURLResponse(
            url: request.url!, statusCode: entry.statusCode,
            httpVersion: nil, headerFields: nil
        )!
        return (entry.data, response)
    }
}

/// Adds a short delay so concurrent sends actually overlap in time.
private final class SlowMockSession: NetworkSession, @unchecked Sendable {
    private(set) var callCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil
        )!
        return (Data(), response)
    }
}

// MARK: - RequestEvent helpers (test-only)

private extension RequestEvent {

    /// The `traceID` carried by any event case.
    var traceID: UUID {
        switch self {
        case .started(let id, _, _):           return id
        case .succeeded(let id, _, _, _):      return id
        case .failed(let id, _, _):            return id
        case .retryScheduled(let id, _, _):    return id
        case .deduplicated(let id, _, _):      return id
        }
    }

    var isStarted:        Bool { if case .started        = self { return true } else { return false } }
    var isSucceeded:      Bool { if case .succeeded      = self { return true } else { return false } }
    var isFailed:         Bool { if case .failed         = self { return true } else { return false } }
    var isRetryScheduled: Bool { if case .retryScheduled = self { return true } else { return false } }
    var isDeduplicated:   Bool { if case .deduplicated   = self { return true } else { return false } }
}

// MARK: - Event sequence tests

/// Verifies that `AsyncRequestEngine` emits the correct `RequestEvent`
/// sequence for each lifecycle path: success, retry, failure, deduplication.
final class RequestEventSequenceTests: XCTestCase {

    private let url = URL(string: "https://api.example.com/test")!

    // MARK: Success path

    func test_successPath_emitsTwoEvents() async throws {
        let sink    = CapturingEventSink()
        let session = MockSession(statusCode: 200)
        let engine  = AsyncRequestEngine(session: session, eventSink: sink)

        try await engine.send(StubRequest(url: url))

        let events = await sink.events
        XCTAssertEqual(events.count, 2)
    }

    func test_successPath_firstEventIsStarted() async throws {
        let sink    = CapturingEventSink()
        let session = MockSession(statusCode: 200)
        let engine  = AsyncRequestEngine(session: session, eventSink: sink)

        try await engine.send(StubRequest(url: url))

        let events = await sink.events
        XCTAssertTrue(events[0].isStarted, "First event must be .started")
    }

    func test_successPath_secondEventIsSucceeded() async throws {
        let sink    = CapturingEventSink()
        let session = MockSession(statusCode: 200)
        let engine  = AsyncRequestEngine(session: session, eventSink: sink)

        try await engine.send(StubRequest(url: url))

        let events = await sink.events
        XCTAssertTrue(events[1].isSucceeded, "Second event must be .succeeded")
    }

    func test_successPath_bothEventsShareTraceID() async throws {
        let sink    = CapturingEventSink()
        let session = MockSession(statusCode: 200)
        let engine  = AsyncRequestEngine(session: session, eventSink: sink)

        try await engine.send(StubRequest(url: url))

        let events = await sink.events
        XCTAssertEqual(events[0].traceID, events[1].traceID)
    }

    func test_successPath_startedCarriesCorrectURLAndMethod() async throws {
        let sink    = CapturingEventSink()
        let session = MockSession(statusCode: 200)
        let engine  = AsyncRequestEngine(session: session, eventSink: sink)

        try await engine.send(StubRequest(url: url, method: .post))

        let events = await sink.events
        guard case let .started(_, eventURL, method) = events[0] else {
            return XCTFail("Expected .started")
        }
        XCTAssertEqual(eventURL, url)
        XCTAssertEqual(method, .post)
    }

    func test_successPath_succeededCarriesStatusCodeAndAttemptZero() async throws {
        let sink    = CapturingEventSink()
        let session = MockSession(statusCode: 201)
        let engine  = AsyncRequestEngine(session: session, eventSink: sink)

        try await engine.send(StubRequest(url: url))

        let events = await sink.events
        guard case let .succeeded(_, statusCode, duration, attempt) = events[1] else {
            return XCTFail("Expected .succeeded")
        }
        XCTAssertEqual(statusCode, 201)
        XCTAssertEqual(attempt, 0, "First-try success must have attempt == 0")
        XCTAssertGreaterThanOrEqual(duration, 0, "Duration must be non-negative")
    }

    // MARK: Retry then success path

    func test_retryThenSuccess_emitsThreeEvents() async throws {
        let entries: [MockSession.Entry] = [
            .init(statusCode: 503, data: Data()),
            .init(statusCode: 200, data: Data())
        ]
        let sink    = CapturingEventSink()
        let session = MockSession(entries)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 1, baseDelay: 0.001),
            eventSink: sink
        )

        try await engine.send(StubRequest(url: url))

        let events = await sink.events
        XCTAssertEqual(events.count, 3)
    }

    func test_retryThenSuccess_eventOrder_startedRetrySucceeded() async throws {
        let entries: [MockSession.Entry] = [
            .init(statusCode: 503, data: Data()),
            .init(statusCode: 200, data: Data())
        ]
        let sink    = CapturingEventSink()
        let session = MockSession(entries)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 1, baseDelay: 0.001),
            eventSink: sink
        )

        try await engine.send(StubRequest(url: url))

        let events = await sink.events
        XCTAssertTrue(events[0].isStarted,        "events[0] must be .started")
        XCTAssertTrue(events[1].isRetryScheduled, "events[1] must be .retryScheduled")
        XCTAssertTrue(events[2].isSucceeded,      "events[2] must be .succeeded")
    }

    func test_retryThenSuccess_retryScheduledCarriesAttemptZeroAndDelay() async throws {
        let entries: [MockSession.Entry] = [
            .init(statusCode: 503, data: Data()),
            .init(statusCode: 200, data: Data())
        ]
        let baseDelay = 0.001
        let sink      = CapturingEventSink()
        let session   = MockSession(entries)
        let engine    = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 1, baseDelay: baseDelay),
            eventSink: sink
        )

        try await engine.send(StubRequest(url: url))

        let events = await sink.events
        guard case let .retryScheduled(_, attempt, delay) = events[1] else {
            return XCTFail("Expected .retryScheduled at events[1]")
        }
        XCTAssertEqual(attempt, 0, "First retry fires after attempt 0")
        XCTAssertEqual(delay, baseDelay, accuracy: 1e-9)
    }

    func test_retryThenSuccess_succeededCarriesAttemptOne() async throws {
        let entries: [MockSession.Entry] = [
            .init(statusCode: 503, data: Data()),
            .init(statusCode: 200, data: Data())
        ]
        let sink    = CapturingEventSink()
        let session = MockSession(entries)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 1, baseDelay: 0.001),
            eventSink: sink
        )

        try await engine.send(StubRequest(url: url))

        let events = await sink.events
        guard case let .succeeded(_, _, _, attempt) = events[2] else {
            return XCTFail("Expected .succeeded at events[2]")
        }
        XCTAssertEqual(attempt, 1, "Success after one retry must have attempt == 1")
    }

    func test_retryThenSuccess_allEventsShareTraceID() async throws {
        let entries: [MockSession.Entry] = [
            .init(statusCode: 503, data: Data()),
            .init(statusCode: 200, data: Data())
        ]
        let sink    = CapturingEventSink()
        let session = MockSession(entries)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 1, baseDelay: 0.001),
            eventSink: sink
        )

        try await engine.send(StubRequest(url: url))

        let events = await sink.events
        let ids = events.map(\.traceID)
        XCTAssertTrue(ids.allSatisfy { $0 == ids[0] }, "All events must share the same traceID")
    }

    // MARK: Non-retryable failure path

    func test_nonRetryableFailure_emitsStartedAndFailed() async throws {
        let sink    = CapturingEventSink()
        let session = MockSession(statusCode: 401) // 4xx — not retryable
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001),
            eventSink: sink
        )

        _ = try? await engine.send(StubRequest(url: url))

        let events = await sink.events
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].isStarted, "events[0] must be .started")
        XCTAssertTrue(events[1].isFailed,  "events[1] must be .failed")
    }

    func test_nonRetryableFailure_failedCarriesAttemptZero() async throws {
        let sink    = CapturingEventSink()
        let session = MockSession(statusCode: 403)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001),
            eventSink: sink
        )

        _ = try? await engine.send(StubRequest(url: url))

        let events = await sink.events
        guard case let .failed(_, _, attempt) = events[1] else {
            return XCTFail("Expected .failed at events[1]")
        }
        XCTAssertEqual(attempt, 0, "Non-retryable error fails on attempt 0 — no retries taken")
    }

    // MARK: Retry exhausted path

    func test_retryExhausted_emitsRetryScheduledBeforeFailed() async throws {
        let entries = Array(
            repeating: MockSession.Entry(statusCode: 503, data: Data()),
            count: 2   // maxRetries: 1 → 1 initial + 1 retry = 2 calls
        )
        let sink    = CapturingEventSink()
        let session = MockSession(entries)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 1, baseDelay: 0.001),
            eventSink: sink
        )

        _ = try? await engine.send(StubRequest(url: url))

        let events = await sink.events
        // Expected: .started, .retryScheduled(attempt:0), .failed(attempt:1)
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events[0].isStarted,        "events[0] must be .started")
        XCTAssertTrue(events[1].isRetryScheduled, "events[1] must be .retryScheduled")
        XCTAssertTrue(events[2].isFailed,          "events[2] must be .failed")
    }

    func test_retryExhausted_failedCarriesAttemptOne() async throws {
        let entries = Array(
            repeating: MockSession.Entry(statusCode: 503, data: Data()),
            count: 2
        )
        let sink    = CapturingEventSink()
        let session = MockSession(entries)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 1, baseDelay: 0.001),
            eventSink: sink
        )

        _ = try? await engine.send(StubRequest(url: url))

        let events = await sink.events
        guard case let .failed(_, _, attempt) = events[2] else {
            return XCTFail("Expected .failed at events[2]")
        }
        XCTAssertEqual(attempt, 1, "After maxRetries: 1, terminal failure is on attempt 1")
    }

    // MARK: Deduplication path

    func test_deduplication_oneStartedOneDeduplicatedOneSucceeded() async throws {
        let sink    = CapturingEventSink()
        let session = SlowMockSession() // 10ms delay ensures overlap
        let engine  = AsyncRequestEngine(session: session, eventSink: sink)
        let request = StubRequest(url: url)

        async let r1 = engine.send(request)
        async let r2 = engine.send(request)
        _ = try await (r1, r2)

        let events = await sink.events
        let startedCount       = events.filter(\.isStarted).count
        let deduplicatedCount  = events.filter(\.isDeduplicated).count
        let succeededCount     = events.filter(\.isSucceeded).count

        XCTAssertEqual(startedCount,      1, "Exactly one request should reach the network")
        XCTAssertEqual(deduplicatedCount, 1, "The second caller should be deduplicated")
        XCTAssertEqual(succeededCount,    1, "Exactly one .succeeded event")
        XCTAssertEqual(session.callCount, 1, "Only one network call should be made")
    }

    func test_deduplication_deduplicatedEventHasDifferentTraceIDFromStarted() async throws {
        let sink    = CapturingEventSink()
        let session = SlowMockSession()
        let engine  = AsyncRequestEngine(session: session, eventSink: sink)
        let request = StubRequest(url: url)

        async let r1 = engine.send(request)
        async let r2 = engine.send(request)
        _ = try await (r1, r2)

        let events = await sink.events
        guard
            let startedEvent       = events.first(where: \.isStarted),
            let deduplicatedEvent  = events.first(where: \.isDeduplicated)
        else {
            return XCTFail("Expected both .started and .deduplicated events")
        }

        XCTAssertNotEqual(
            startedEvent.traceID, deduplicatedEvent.traceID,
            ".deduplicated must carry its own fresh traceID — not the canonical request's"
        )
    }

    func test_deduplication_deduplicatedCarriesCorrectURLAndMethod() async throws {
        let sink    = CapturingEventSink()
        let session = SlowMockSession()
        let engine  = AsyncRequestEngine(session: session, eventSink: sink)
        let request = StubRequest(url: url, method: .post)

        async let r1 = engine.send(request)
        async let r2 = engine.send(request)
        _ = try await (r1, r2)

        let events = await sink.events
        guard let deduplicatedEvent = events.first(where: \.isDeduplicated),
              case let .deduplicated(_, eventURL, method) = deduplicatedEvent
        else {
            return XCTFail("Expected .deduplicated event")
        }

        XCTAssertEqual(eventURL, url)
        XCTAssertEqual(method, .post)
    }
}

// MARK: - RequestMetricsCollector counter tests

/// Verifies that `RequestMetricsCollector` accumulates counters correctly by
/// calling `record()` directly with crafted events — no engine or network needed.
final class RequestMetricsCollectorCounterTests: XCTestCase {

    private let id  = UUID()
    private let url = URL(string: "https://api.example.com/test")!

    // MARK: Individual event counters

    func test_started_incrementsRequestsStarted() async {
        let collector = RequestMetricsCollector()
        await collector.record(.started(traceID: id, url: url, method: .get))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.requestsStarted, 1)
        XCTAssertEqual(stats.requestsSucceeded, 0)
        XCTAssertEqual(stats.requestsFailed, 0)
    }

    func test_succeeded_incrementsRequestsSucceeded() async {
        let collector = RequestMetricsCollector()
        await collector.record(.succeeded(traceID: id, statusCode: 200, duration: 0.1, attempt: 0))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.requestsSucceeded, 1)
        XCTAssertEqual(stats.requestsStarted, 0)
        XCTAssertEqual(stats.requestsFailed, 0)
    }

    func test_failed_incrementsRequestsFailed() async {
        let collector = RequestMetricsCollector()
        await collector.record(.failed(
            traceID: id,
            error: .httpError(statusCode: 500, data: nil),
            attempt: 0
        ))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.requestsFailed, 1)
        XCTAssertEqual(stats.requestsStarted, 0)
        XCTAssertEqual(stats.requestsSucceeded, 0)
    }

    func test_retryScheduled_incrementsRetriesScheduled() async {
        let collector = RequestMetricsCollector()
        await collector.record(.retryScheduled(traceID: id, attempt: 0, delay: 1.0))
        await collector.record(.retryScheduled(traceID: id, attempt: 1, delay: 2.0))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.retriesScheduled, 2)
    }

    func test_deduplicated_incrementsDeduplicationsHit() async {
        let collector = RequestMetricsCollector()
        await collector.record(.deduplicated(traceID: id, url: url, method: .get))
        await collector.record(.deduplicated(traceID: id, url: url, method: .get))
        await collector.record(.deduplicated(traceID: id, url: url, method: .get))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.deduplicationsHit, 3)
    }

    // MARK: Accumulation across multiple requests

    func test_multipleRequests_allCountersAccumulateCorrectly() async {
        let collector = RequestMetricsCollector()
        let id2 = UUID()

        // Request 1: started → retryScheduled → succeeded
        await collector.record(.started(traceID: id,  url: url, method: .get))
        await collector.record(.retryScheduled(traceID: id, attempt: 0, delay: 0.5))
        await collector.record(.succeeded(traceID: id, statusCode: 200, duration: 0.6, attempt: 1))

        // Request 2: started → failed
        await collector.record(.started(traceID: id2, url: url, method: .post))
        await collector.record(.failed(traceID: id2, error: .noConnection, attempt: 0))

        // Deduplication hit
        await collector.record(.deduplicated(traceID: UUID(), url: url, method: .get))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.requestsStarted,   2)
        XCTAssertEqual(stats.requestsSucceeded, 1)
        XCTAssertEqual(stats.requestsFailed,    1)
        XCTAssertEqual(stats.retriesScheduled,  1)
        XCTAssertEqual(stats.deduplicationsHit, 1)
    }

    // MARK: Reset

    func test_reset_clearsAllCounters() async {
        let collector = RequestMetricsCollector()
        await collector.record(.started(traceID: id, url: url, method: .get))
        await collector.record(.succeeded(traceID: id, statusCode: 200, duration: 0.1, attempt: 0))
        await collector.record(.retryScheduled(traceID: id, attempt: 0, delay: 1.0))
        await collector.record(.deduplicated(traceID: id, url: url, method: .get))

        await collector.reset()

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.requestsStarted,   0)
        XCTAssertEqual(stats.requestsSucceeded, 0)
        XCTAssertEqual(stats.requestsFailed,    0)
        XCTAssertEqual(stats.retriesScheduled,  0)
        XCTAssertEqual(stats.deduplicationsHit, 0)
    }

    func test_reset_allowsNewAccumulationAfterClear() async {
        let collector = RequestMetricsCollector()

        // First window
        await collector.record(.started(traceID: id, url: url, method: .get))
        await collector.record(.succeeded(traceID: id, statusCode: 200, duration: 2.0, attempt: 0))
        await collector.reset()

        // Second window
        let id2 = UUID()
        await collector.record(.started(traceID: id2, url: url, method: .get))
        await collector.record(.succeeded(traceID: id2, statusCode: 200, duration: 0.5, attempt: 0))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.requestsStarted,   1)
        XCTAssertEqual(stats.requestsSucceeded, 1)
    }
}

// MARK: - RequestMetrics derived property tests

/// Verifies the computed properties on `RequestMetrics`: `averageSuccessDuration`
/// and `successRate`. These are exercised via direct `record()` calls so the
/// values are deterministic — no floating-point wall-clock uncertainty.
final class RequestMetricsDerivedTests: XCTestCase {

    private let id  = UUID()
    private let url = URL(string: "https://api.example.com/test")!

    // MARK: averageSuccessDuration

    func test_averageSuccessDuration_nilWhenNoSuccesses() async {
        let collector = RequestMetricsCollector()
        await collector.record(.started(traceID: id, url: url, method: .get))

        let stats = await collector.snapshot()
        XCTAssertNil(stats.averageSuccessDuration)
    }

    func test_averageSuccessDuration_singleSuccess_equalsDuration() async {
        let collector = RequestMetricsCollector()
        await collector.record(.succeeded(traceID: id, statusCode: 200, duration: 0.42, attempt: 0))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.averageSuccessDuration, 0.42, accuracy: 1e-9)
    }

    func test_averageSuccessDuration_multipleSuccesses_returnsCorrectMean() async {
        let collector = RequestMetricsCollector()
        await collector.record(.succeeded(traceID: UUID(), statusCode: 200, duration: 1.0, attempt: 0))
        await collector.record(.succeeded(traceID: UUID(), statusCode: 200, duration: 3.0, attempt: 0))

        let stats = await collector.snapshot()
        // Mean of 1.0 and 3.0 = 2.0
        XCTAssertEqual(stats.averageSuccessDuration, 2.0, accuracy: 1e-9)
    }

    // MARK: successRate

    func test_successRate_nilWhenNoCompletedRequests() async {
        let collector = RequestMetricsCollector()
        await collector.record(.started(traceID: id, url: url, method: .get))
        await collector.record(.deduplicated(traceID: UUID(), url: url, method: .get))

        let stats = await collector.snapshot()
        XCTAssertNil(stats.successRate, "successRate must be nil until at least one request completes")
    }

    func test_successRate_allSucceeded_returnsOne() async {
        let collector = RequestMetricsCollector()
        await collector.record(.succeeded(traceID: UUID(), statusCode: 200, duration: 0.1, attempt: 0))
        await collector.record(.succeeded(traceID: UUID(), statusCode: 200, duration: 0.2, attempt: 0))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.successRate, 1.0, accuracy: 1e-9)
    }

    func test_successRate_allFailed_returnsZero() async {
        let collector = RequestMetricsCollector()
        await collector.record(.failed(traceID: UUID(), error: .noConnection, attempt: 0))
        await collector.record(.failed(traceID: UUID(), error: .timedOut,     attempt: 0))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.successRate, 0.0, accuracy: 1e-9)
    }

    func test_successRate_mixedOutcomes_returnsCorrectRatio() async {
        let collector = RequestMetricsCollector()
        // 3 successes, 1 failure → 0.75
        for _ in 0..<3 {
            await collector.record(.succeeded(traceID: UUID(), statusCode: 200, duration: 0.1, attempt: 0))
        }
        await collector.record(.failed(traceID: UUID(), error: .noConnection, attempt: 0))

        let stats = await collector.snapshot()
        XCTAssertEqual(stats.successRate, 0.75, accuracy: 1e-9)
    }

    func test_successRate_excludesDeduplicationsFromDenominator() async {
        let collector = RequestMetricsCollector()
        await collector.record(.succeeded(traceID: UUID(), statusCode: 200, duration: 0.1, attempt: 0))
        // Dedup hits must NOT count as failures or completions
        await collector.record(.deduplicated(traceID: UUID(), url: url, method: .get))
        await collector.record(.deduplicated(traceID: UUID(), url: url, method: .get))

        let stats = await collector.snapshot()
        // Only 1 completed (succeeded) out of 1 total completions = 100%
        XCTAssertEqual(stats.successRate, 1.0, accuracy: 1e-9,
            "Deduplication hits must not be counted as completed requests in successRate")
    }

    func test_successRate_excludesInProgressFromDenominator() async {
        let collector = RequestMetricsCollector()
        // started but not yet completed
        await collector.record(.started(traceID: UUID(), url: url, method: .get))
        // one completed success
        await collector.record(.succeeded(traceID: UUID(), statusCode: 200, duration: 0.1, attempt: 0))

        let stats = await collector.snapshot()
        // successRate denominator = succeeded + failed = 1 + 0 = 1
        XCTAssertEqual(stats.successRate, 1.0, accuracy: 1e-9,
            "In-progress requests (.started without .succeeded/.failed) must not affect successRate")
    }
}
