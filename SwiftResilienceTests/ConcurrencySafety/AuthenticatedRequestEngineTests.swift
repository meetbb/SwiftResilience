//
//  AuthenticatedRequestEngineTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 08/06/26.
//

import XCTest
@testable import SwiftResilience

// MARK: - Test infrastructure

/// Configurable mock TokenProvider. Mutable properties are set before each test
/// and read after — @unchecked Sendable is safe because there is no concurrent
/// mutation within a single test.
private final class MockTokenProvider: TokenProvider, @unchecked Sendable {
    var stubbedCurrentToken: String? = "current-token"
    var stubbedRefreshedToken: String = "refreshed-token"
    var stubbedRefreshError: Error? = nil
    var refreshDelay: UInt64 = 0   // nanoseconds; non-zero ensures concurrent calls overlap

    private(set) var refreshCallCount = 0

    func currentToken() async -> String? {
        stubbedCurrentToken
    }

    func refreshToken() async throws -> String {
        refreshCallCount += 1
        if refreshDelay > 0 {
            try await Task.sleep(nanoseconds: refreshDelay)
        }
        if let error = stubbedRefreshError { throw error }
        stubbedCurrentToken = stubbedRefreshedToken
        return stubbedRefreshedToken
    }
}

/// Returns a fixed status code for every call. Captures each URLRequest so
/// tests can inspect injected headers.
private final class FixedStatusSession: NetworkSession, @unchecked Sendable {
    let statusCode: Int
    let data: Data
    private(set) var receivedRequests: [URLRequest] = []

    init(statusCode: Int = 200, data: Data = Data()) {
        self.statusCode = statusCode
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        receivedRequests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

/// Returns responses in the order they were provided. Crashes if more calls are
/// made than entries — intentional, so tests fail loudly on unexpected calls.
private final class SequenceSession: NetworkSession, @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let data: Data
        init(statusCode: Int, data: Data = Data()) {
            self.statusCode = statusCode
            self.data = data
        }
    }

    private let responses: [Response]
    private var index = 0
    private(set) var receivedRequests: [URLRequest] = []

    init(_ responses: Response...) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        receivedRequests.append(request)
        let entry = responses[index]
        index += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: entry.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (entry.data, response)
    }
}

/// Inspects the `Authorization` header and returns 200 only when it matches
/// the configured valid token. Returns 401 for any other value or absence.
/// Used in 401-refresh-retry and concurrency tests to eliminate sequence
/// dependencies — responses are driven by the token value, not call order.
private final class TokenAwareSession: NetworkSession, @unchecked Sendable {
    let validToken: String
    private(set) var callCount = 0

    init(validToken: String) { self.validToken = validToken }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        let authHeader = request.value(forHTTPHeaderField: "Authorization")
        let statusCode = authHeader == "Bearer \(validToken)" ? 200 : 401
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}

// Minimal NetworkRequest used throughout these tests.
private struct StubRequest: NetworkRequest {
    var url     = URL(string: "https://api.example.com/posts")!
    var method  = HTTPMethod.get
    var headers = [String: String]()
}

// MARK: - Token injection

final class AuthenticatedRequestEngineTokenInjectionTests: XCTestCase {

    func test_send_injectsCurrentTokenAsDefaultAuthorizationHeader() async throws {
        let session = FixedStatusSession(statusCode: 200)
        let provider = MockTokenProvider()
        provider.stubbedCurrentToken = "abc123"
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: TokenRefreshCoordinator(provider: provider)
        )

        try await engine.send(StubRequest())

        let authHeader = session.receivedRequests.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer abc123")
    }

    func test_send_nilToken_sendsWithoutAuthorizationHeader() async throws {
        let session = FixedStatusSession(statusCode: 200)
        let provider = MockTokenProvider()
        provider.stubbedCurrentToken = nil
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: TokenRefreshCoordinator(provider: provider)
        )

        try await engine.send(StubRequest())

        let authHeader = session.receivedRequests.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertNil(authHeader, "No Authorization header should be injected when the user is not authenticated.")
    }

    func test_send_customTokenHeaderName_usesConfiguredName() async throws {
        let session = FixedStatusSession(statusCode: 200)
        let provider = MockTokenProvider()
        provider.stubbedCurrentToken = "tok"
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: TokenRefreshCoordinator(provider: provider),
            tokenHeaderName: "X-API-Key",
            tokenPrefix: ""
        )

        try await engine.send(StubRequest())

        let apiKey = session.receivedRequests.first?.value(forHTTPHeaderField: "X-API-Key")
        XCTAssertEqual(apiKey, "tok")
        let authHeader = session.receivedRequests.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertNil(authHeader, "Default Authorization header must not be set when a custom header is configured.")
    }

    func test_send_customPrefix_prependedToToken() async throws {
        let session = FixedStatusSession(statusCode: 200)
        let provider = MockTokenProvider()
        provider.stubbedCurrentToken = "tok"
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: TokenRefreshCoordinator(provider: provider),
            tokenPrefix: "Token "
        )

        try await engine.send(StubRequest())

        let authHeader = session.receivedRequests.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Token tok")
    }

    func test_send_preservesExistingRequestHeaders() async throws {
        let session = FixedStatusSession(statusCode: 200)
        let provider = MockTokenProvider()
        var request = StubRequest()
        request.headers = ["X-Request-ID": "req-42", "Accept": "application/json"]
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: TokenRefreshCoordinator(provider: provider)
        )

        try await engine.send(request)

        let received = session.receivedRequests.first
        XCTAssertEqual(received?.value(forHTTPHeaderField: "X-Request-ID"), "req-42")
        XCTAssertEqual(received?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNotNil(received?.value(forHTTPHeaderField: "Authorization"), "Auth header should be added alongside existing headers.")
    }
}

// MARK: - 401 refresh and retry

final class AuthenticatedRequestEngine401Tests: XCTestCase {

    func test_send_on401_refreshesAndRetries_withNewToken() async throws {
        // Session returns 401 with old token, 200 with new token.
        let session = TokenAwareSession(validToken: "refreshed-token")
        let provider = MockTokenProvider()
        provider.stubbedCurrentToken = "expired-token"
        provider.stubbedRefreshedToken = "refreshed-token"
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: TokenRefreshCoordinator(provider: provider)
        )

        // Should succeed — engine transparently refreshes and retries.
        try await engine.send(StubRequest())

        XCTAssertEqual(provider.refreshCallCount, 1, "Refresh should be called exactly once on 401.")
        XCTAssertEqual(session.callCount, 2, "Two network calls: initial (401) + retry (200).")
    }

    func test_send_retryAlso401_throwsWithoutFurtherRefresh() async throws {
        // Session always returns 401 — the refresh token itself is invalid.
        let session = TokenAwareSession(validToken: "nobody-has-this-token")
        let provider = MockTokenProvider()
        provider.stubbedRefreshedToken = "still-wrong-token"
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: TokenRefreshCoordinator(provider: provider)
        )

        do {
            try await engine.send(StubRequest())
            XCTFail("Expected NetworkError.httpError(401) to be thrown.")
        } catch NetworkError.httpError(let code, _) {
            XCTAssertEqual(code, 401)
        }

        XCTAssertEqual(provider.refreshCallCount, 1, "Refresh should only fire once — no infinite retry loop.")
    }

    func test_send_non401HttpError_rethrowsWithoutRefresh() async throws {
        let session = FixedStatusSession(statusCode: 403)
        let provider = MockTokenProvider()
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: TokenRefreshCoordinator(provider: provider)
        )

        do {
            try await engine.send(StubRequest())
            XCTFail("Expected NetworkError.httpError(403) to be thrown.")
        } catch NetworkError.httpError(let code, _) {
            XCTAssertEqual(code, 403)
        }

        XCTAssertEqual(provider.refreshCallCount, 0, "A 403 Forbidden must not trigger a token refresh.")
    }

    func test_send_serverError500_rethrowsWithoutRefresh() async throws {
        let session = FixedStatusSession(statusCode: 500)
        let provider = MockTokenProvider()
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: TokenRefreshCoordinator(provider: provider)
        )

        do {
            try await engine.send(StubRequest())
            XCTFail("Expected NetworkError.httpError(500) to be thrown.")
        } catch NetworkError.httpError(let code, _) {
            XCTAssertEqual(code, 500)
        }

        XCTAssertEqual(provider.refreshCallCount, 0, "A 500 error must not trigger a token refresh.")
    }

    func test_send_refreshError_propagatesToCaller() async throws {
        struct SessionExpiredError: Error {}

        let session = TokenAwareSession(validToken: "new-token")
        let provider = MockTokenProvider()
        provider.stubbedCurrentToken = "expired-token"
        provider.stubbedRefreshError = SessionExpiredError()
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: TokenRefreshCoordinator(provider: provider)
        )

        do {
            try await engine.send(StubRequest())
            XCTFail("Expected SessionExpiredError to be thrown.")
        } catch is SessionExpiredError {
            // The app should redirect to the login screen here.
        }
    }
}

// MARK: - Concurrent 401 coalescing

final class AuthenticatedRequestEngineConcurrencyTests: XCTestCase {

    /// Fires 4 concurrent requests. All get 401 on their initial attempt because
    /// they carry the old token. The coordinator must coalesce those 4 concurrent
    /// refresh calls into exactly one `TokenProvider.refreshToken()` call.
    /// All 4 retries should then succeed with the new token.
    func test_send_concurrent401s_onlyOneRefreshCallFires() async throws {
        let provider = MockTokenProvider()
        provider.stubbedCurrentToken = "old-token"
        provider.stubbedRefreshedToken = "new-token"
        // 50ms delay ensures all 4 concurrent callers queue up behind the
        // first refresh task before it completes.
        provider.refreshDelay = 50_000_000

        let session = TokenAwareSession(validToken: "new-token")
        let coordinator = TokenRefreshCoordinator(provider: provider)
        let engine = AuthenticatedRequestEngine(
            requestEngine: AsyncRequestEngine(session: session),
            coordinator: coordinator
        )

        var successCount = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do {
                        try await engine.send(StubRequest())
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await succeeded in group {
                if succeeded { successCount += 1 }
            }
        }

        XCTAssertEqual(successCount, 4, "All 4 concurrent requests should eventually succeed.")
        XCTAssertEqual(
            provider.refreshCallCount, 1,
            "Despite 4 concurrent 401s, TokenProvider.refreshToken() must be called exactly once."
        )
        // 4 initial attempts (all 401) + 4 retries (all 200) = 8 total calls.
        XCTAssertEqual(session.callCount, 8)
    }
}
