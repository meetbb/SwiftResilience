//
//  AsyncRequestEngineTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import XCTest
@testable import SwiftResilience

// MARK: - Test doubles

// A bare-minimum NetworkRequest for tests.
private struct StubRequest: NetworkRequest {
    let url: URL
    var method: HTTPMethod = .get
}

// Feeds pre-baked responses to the engine one by one.
// If more requests are made than entries provided, it crashes loudly —
// which is intentional so tests don't silently pass with extra calls.
private final class MockNetworkSession: NetworkSession, @unchecked Sendable {

    struct Entry {
        let data: Data
        let statusCode: Int
    }

    private var entries: [Entry]
    private(set) var callCount = 0

    init(entries: [Entry]) {
        self.entries = entries
    }

    convenience init(data: Data = Data(), statusCode: Int = 200) {
        self.init(entries: [Entry(data: data, statusCode: statusCode)])
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
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

// Always throws the given error. Useful for connection/timeout scenarios.
private final class FailingNetworkSession: NetworkSession, @unchecked Sendable {
    let error: Error
    private(set) var callCount = 0

    init(error: Error) { self.error = error }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        throw error
    }
}

// Tracks how many times data(for:) was called across concurrent requests.
// Used in deduplication tests to confirm only one network call was made.
private final class CountingNetworkSession: NetworkSession, @unchecked Sendable {
    private(set) var callCount = 0
    let responseData: Data
    let statusCode: Int

    init(data: Data = Data("ok".utf8), statusCode: Int = 200) {
        self.responseData = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        // Small delay so concurrent callers actually overlap in time.
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }
}

// MARK: - Tests

final class AsyncRequestEngineTests: XCTestCase {

    private let testURL = URL(string: "https://example.com/api")!

    // MARK: Success

    func testSuccessfulRequestReturnsData() async throws {
        let expected = Data("hello".utf8)
        let session  = MockNetworkSession(data: expected, statusCode: 200)
        let engine   = AsyncRequestEngine(session: session)

        let (data, response) = try await engine.send(StubRequest(url: testURL))

        XCTAssertEqual(data, expected)
        XCTAssertEqual(response.statusCode, 200)
    }

    // MARK: HTTP errors

    func testPermanent4xxThrowsWithoutRetry() async throws {
        let session = MockNetworkSession(statusCode: 401)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001)
        )

        do {
            _ = try await engine.send(StubRequest(url: testURL))
            XCTFail("Expected an error")
        } catch NetworkError.httpError(let statusCode, _) {
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(session.callCount, 1) // no retries
        }
    }

    func testTransient503ExhaustsRetriesAndThrows() async throws {
        let entries = Array(repeating: MockNetworkSession.Entry(data: Data(), statusCode: 503), count: 4)
        let session = MockNetworkSession(entries: entries)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001)
        )

        do {
            _ = try await engine.send(StubRequest(url: testURL))
            XCTFail("Expected an error")
        } catch NetworkError.httpError(let statusCode, _) {
            XCTAssertEqual(statusCode, 503)
            XCTAssertEqual(session.callCount, 4) // 1 initial + 3 retries
        }
    }

    func testSucceedsAfterOneRetry() async throws {
        let entries: [MockNetworkSession.Entry] = [
            .init(data: Data(), statusCode: 503),
            .init(data: Data("ok".utf8), statusCode: 200)
        ]
        let session = MockNetworkSession(entries: entries)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001)
        )

        let (data, response) = try await engine.send(StubRequest(url: testURL))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("ok".utf8))
        XCTAssertEqual(session.callCount, 2)
    }

    // MARK: Network errors

    func testNoConnectionWithNoPolicyThrowsImmediately() async throws {
        let session = FailingNetworkSession(error: URLError(.notConnectedToInternet))
        let engine  = AsyncRequestEngine(session: session)

        do {
            _ = try await engine.send(StubRequest(url: testURL))
            XCTFail("Expected an error")
        } catch NetworkError.noConnection {
            XCTAssertEqual(session.callCount, 1)
        }
    }

    func testNoConnectionRetriesWithPolicy() async throws {
        let session = FailingNetworkSession(error: URLError(.notConnectedToInternet))
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001)
        )

        do {
            _ = try await engine.send(StubRequest(url: testURL))
            XCTFail("Expected an error")
        } catch NetworkError.noConnection {
            XCTAssertEqual(session.callCount, 4) // 1 initial + 3 retries
        }
    }

    func testCancelledErrorIsNotRetried() async throws {
        let session = FailingNetworkSession(error: URLError(.cancelled))
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001)
        )

        do {
            _ = try await engine.send(StubRequest(url: testURL))
            XCTFail("Expected an error")
        } catch NetworkError.cancelled {
            XCTAssertEqual(session.callCount, 1) // cancelled = no retries
        }
    }

    // MARK: Deduplication

    func testIdenticalConcurrentRequestsShareOneNetworkCall() async throws {
        let session = CountingNetworkSession()
        let engine  = AsyncRequestEngine(session: session)
        let request = StubRequest(url: testURL)

        // Fire the same request from three concurrent tasks.
        async let r1 = engine.send(request)
        async let r2 = engine.send(request)
        async let r3 = engine.send(request)

        let results = try await [r1.0, r2.0, r3.0]

        // All three should get the same data back.
        XCTAssertTrue(results.allSatisfy { $0 == Data("ok".utf8) })
        // But the network should have been hit only once.
        XCTAssertEqual(session.callCount, 1)
    }

    func testDifferentRequestsDoNotShareTasks() async throws {
        let urlA = URL(string: "https://example.com/a")!
        let urlB = URL(string: "https://example.com/b")!
        let session = CountingNetworkSession()
        let engine  = AsyncRequestEngine(session: session)

        async let r1 = engine.send(StubRequest(url: urlA))
        async let r2 = engine.send(StubRequest(url: urlB))

        _ = try await (r1, r2)

        // Different URLs = different identities = two separate network calls.
        XCTAssertEqual(session.callCount, 2)
    }
}
