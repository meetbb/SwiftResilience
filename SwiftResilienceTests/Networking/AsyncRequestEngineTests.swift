//
//  AsyncRequestEngineTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import XCTest
@testable import SwiftResilience

// MARK: - Test doubles

/// A minimal `NetworkRequest` for use in tests.
///
/// Defined here, not in production code, because it's a test utility.
/// Real consumers create their own concrete request types.
private struct StubRequest: NetworkRequest {
    let url: URL
    var method: HTTPMethod = .get
}

/// A controllable stand-in for `URLSession`.
///
/// Each `responses` entry is consumed in order. Once all entries are
/// consumed, calling `data(for:)` again will crash with an index
/// out-of-bounds — which is intentional: a test that fires more
/// requests than it expected should fail loudly.
///
/// `@unchecked Sendable` is safe here because `MockNetworkSession` is
/// only ever used from one concurrency context in tests.
private final class MockNetworkSession: NetworkSession, @unchecked Sendable {

    struct Entry {
        let data: Data
        let statusCode: Int
    }

    private var entries: [Entry]
    private var callIndex = 0

    /// Designated initialiser for success/HTTP-error scenarios.
    init(entries: [Entry]) {
        self.entries = entries
    }

    /// Convenience for a single successful 200 response.
    convenience init(data: Data = Data(), statusCode: Int = 200) {
        self.init(entries: [Entry(data: data, statusCode: statusCode)])
    }

    var requestsReceived: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestsReceived.append(request)
        let entry = entries[callIndex]
        callIndex += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: entry.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (entry.data, response)
    }
}

/// A session that always throws a given error.
private final class FailingNetworkSession: NetworkSession, @unchecked Sendable {
    let error: Error
    private(set) var callCount = 0

    init(error: Error) { self.error = error }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        throw error
    }
}

// MARK: - Tests

final class AsyncRequestEngineTests: XCTestCase {

    private let testURL = URL(string: "https://example.com/api")!

    // MARK: Success

    func testSuccessfulRequestReturnsData() async throws {
        let expectedData = Data("hello".utf8)
        let session = MockNetworkSession(data: expectedData, statusCode: 200)
        let engine  = AsyncRequestEngine(session: session)

        let (data, response) = try await engine.send(StubRequest(url: testURL))

        XCTAssertEqual(data, expectedData)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(session.requestsReceived.count, 1)
    }

    // MARK: HTTP errors

    func testPermanent4xxThrowsImmediatelyWithoutRetry() async throws {
        // 401 Unauthorized is a client error — retrying won't change the outcome.
        let session = MockNetworkSession(statusCode: 401)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001)
        )

        do {
            _ = try await engine.send(StubRequest(url: testURL))
            XCTFail("Expected httpError to be thrown")
        } catch NetworkError.httpError(let statusCode, _) {
            XCTAssertEqual(statusCode, 401)
            // Only 1 attempt — policy was never consulted.
            XCTAssertEqual(session.requestsReceived.count, 1)
        }
    }

    func testTransient503RetriesUpToMaxAndThenThrows() async throws {
        // Server returns 503 on every attempt → should exhaust policy (3 retries)
        // and throw on the 4th attempt (attempts 0, 1, 2 retry; attempt 3 is final).
        let entries = Array(repeating: MockNetworkSession.Entry(data: Data(), statusCode: 503),
                            count: 4)
        let session = MockNetworkSession(entries: entries)
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001)
        )

        do {
            _ = try await engine.send(StubRequest(url: testURL))
            XCTFail("Expected httpError to be thrown after retries")
        } catch NetworkError.httpError(let statusCode, _) {
            XCTAssertEqual(statusCode, 503)
            // 1 initial attempt + 3 retries = 4 total requests.
            XCTAssertEqual(session.requestsReceived.count, 4)
        }
    }

    func testSucceedsAfterOneRetry() async throws {
        // First attempt fails with 503; second succeeds with 200.
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
        XCTAssertEqual(session.requestsReceived.count, 2)
    }

    // MARK: Network errors

    func testNoConnectionWithoutPolicyThrowsImmediately() async throws {
        let session = FailingNetworkSession(error: URLError(.notConnectedToInternet))
        let engine  = AsyncRequestEngine(session: session) // no retry policy

        do {
            _ = try await engine.send(StubRequest(url: testURL))
            XCTFail("Expected noConnection to be thrown")
        } catch NetworkError.noConnection {
            XCTAssertEqual(session.callCount, 1)
        }
    }

    func testNoConnectionRetriesWithPolicy() async throws {
        // 3 connection failures → policy exhausted → throws .noConnection
        let session = FailingNetworkSession(error: URLError(.notConnectedToInternet))
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001)
        )

        do {
            _ = try await engine.send(StubRequest(url: testURL))
            XCTFail("Expected noConnection to be thrown after retries")
        } catch NetworkError.noConnection {
            // 1 initial + 3 retries = 4 total calls.
            XCTAssertEqual(session.callCount, 4)
        }
    }

    // MARK: Cancellation

    func testCancelledTaskThrowsCancelledError() async throws {
        let session = FailingNetworkSession(error: URLError(.cancelled))
        let engine  = AsyncRequestEngine(
            session: session,
            retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 0.001)
        )

        do {
            _ = try await engine.send(StubRequest(url: testURL))
            XCTFail("Expected cancelled to be thrown")
        } catch NetworkError.cancelled {
            // Cancellation should NOT trigger retries — only 1 call.
            XCTAssertEqual(session.callCount, 1)
        }
    }
}
