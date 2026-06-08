//
//  TokenRefreshCoordinatorTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 08/06/26.
//

import XCTest
@testable import SwiftResilience

// MARK: - Test infrastructure

/// Configurable mock. All mutable properties are set before the test and read
/// after, so @unchecked Sendable is safe here — no concurrent mutation.
private final class MockTokenProvider: TokenProvider, @unchecked Sendable {
    var stubbedCurrentToken: String? = "current-token"
    var stubbedRefreshedToken: String = "refreshed-token"
    var stubbedRefreshError: Error? = nil

    /// Optional delay before `refreshToken()` returns, in nanoseconds.
    /// Set a non-zero value in concurrent tests so callers actually overlap in time.
    var refreshDelay: UInt64 = 0

    private(set) var currentTokenCallCount = 0
    private(set) var refreshCallCount = 0

    func currentToken() async -> String? {
        currentTokenCallCount += 1
        return stubbedCurrentToken
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

// Sentinel error for refresh-failure tests.
private struct RefreshError: Error, Equatable {}

// MARK: - currentToken delegation

final class TokenRefreshCoordinatorCurrentTokenTests: XCTestCase {

    func test_currentToken_delegatesToProvider() async {
        let provider = MockTokenProvider()
        provider.stubbedCurrentToken = "my-access-token"
        let coordinator = TokenRefreshCoordinator(provider: provider)

        let token = await coordinator.currentToken()

        XCTAssertEqual(token, "my-access-token")
        XCTAssertEqual(provider.currentTokenCallCount, 1)
    }

    func test_currentToken_nilWhenProviderReturnsNil() async {
        let provider = MockTokenProvider()
        provider.stubbedCurrentToken = nil
        let coordinator = TokenRefreshCoordinator(provider: provider)

        let token = await coordinator.currentToken()

        XCTAssertNil(token)
    }
}

// MARK: - Single-caller refresh

final class TokenRefreshCoordinatorSingleRefreshTests: XCTestCase {

    func test_refresh_returnsProviderToken() async throws {
        let provider = MockTokenProvider()
        provider.stubbedRefreshedToken = "brand-new-token"
        let coordinator = TokenRefreshCoordinator(provider: provider)

        let token = try await coordinator.refresh()

        XCTAssertEqual(token, "brand-new-token")
    }

    func test_refresh_callsProviderExactlyOnce() async throws {
        let provider = MockTokenProvider()
        let coordinator = TokenRefreshCoordinator(provider: provider)

        _ = try await coordinator.refresh()

        XCTAssertEqual(provider.refreshCallCount, 1)
    }

    func test_refresh_sequential_eachStartsFreshRefresh() async throws {
        let provider = MockTokenProvider()
        let coordinator = TokenRefreshCoordinator(provider: provider)

        _ = try await coordinator.refresh()
        _ = try await coordinator.refresh()

        // Two sequential calls — the task is cleared between them, so the
        // provider should be called twice, not once.
        XCTAssertEqual(provider.refreshCallCount, 2)
    }

    func test_refresh_failure_propagatesToCaller() async throws {
        let provider = MockTokenProvider()
        provider.stubbedRefreshError = RefreshError()
        let coordinator = TokenRefreshCoordinator(provider: provider)

        do {
            _ = try await coordinator.refresh()
            XCTFail("Expected RefreshError to be thrown.")
        } catch is RefreshError {
            // expected
        }
    }

    func test_refresh_afterFailure_canRetrySuccessfully() async throws {
        let provider = MockTokenProvider()
        provider.stubbedRefreshError = RefreshError()
        let coordinator = TokenRefreshCoordinator(provider: provider)

        // First attempt fails.
        _ = try? await coordinator.refresh()

        // Clear the error — second attempt should succeed.
        provider.stubbedRefreshError = nil
        let token = try await coordinator.refresh()

        XCTAssertEqual(token, "refreshed-token")
        XCTAssertEqual(provider.refreshCallCount, 2)
    }
}

// MARK: - Concurrent coalescing (the key behaviour)

final class TokenRefreshCoordinatorConcurrentTests: XCTestCase {

    /// Fires 5 concurrent refresh calls and verifies that `TokenProvider.refreshToken()`
    /// was called exactly once. This is the core invariant of the coordinator.
    func test_refresh_concurrent_coalescesIntoOneProviderCall() async throws {
        let provider = MockTokenProvider()
        // 50ms delay ensures all 5 tasks are queued behind the first one
        // before the refresh completes.
        provider.refreshDelay = 50_000_000
        let coordinator = TokenRefreshCoordinator(provider: provider)

        var tokens: [String] = []

        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try? await coordinator.refresh()
                }
            }
            for await token in group {
                if let token { tokens.append(token) }
            }
        }

        XCTAssertEqual(tokens.count, 5, "All 5 callers should receive a token.")
        XCTAssertTrue(
            tokens.allSatisfy { $0 == "refreshed-token" },
            "All callers should receive the same refreshed token."
        )
        XCTAssertEqual(
            provider.refreshCallCount, 1,
            "Despite 5 concurrent callers, provider.refreshToken() should be called exactly once."
        )
    }

    /// Verifies that a refresh failure propagates to every caller that was
    /// coalesced into the same refresh task.
    func test_refresh_concurrent_failure_propagatesToAllCallers() async throws {
        let provider = MockTokenProvider()
        provider.stubbedRefreshError = RefreshError()
        provider.refreshDelay = 50_000_000
        let coordinator = TokenRefreshCoordinator(provider: provider)

        var errorCount = 0

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        _ = try await coordinator.refresh()
                        return false  // did NOT receive an error — unexpected
                    } catch {
                        return true   // received an error — expected
                    }
                }
            }
            for await receivedError in group {
                if receivedError { errorCount += 1 }
            }
        }

        XCTAssertEqual(
            errorCount, 3,
            "Every concurrent caller should receive the refresh error."
        )
        XCTAssertEqual(
            provider.refreshCallCount, 1,
            "The provider should only be called once even when all callers fail."
        )
    }

    /// After a concurrent batch completes, the next call starts a new refresh
    /// rather than reusing the completed (and cleared) task.
    func test_refresh_concurrentBatch_thenSequential_startsFreshRefresh() async throws {
        let provider = MockTokenProvider()
        provider.refreshDelay = 50_000_000
        let coordinator = TokenRefreshCoordinator(provider: provider)

        // First concurrent batch.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { _ = try? await coordinator.refresh() }
            }
        }

        // Sequential call after the batch — should trigger a new refresh.
        _ = try await coordinator.refresh()

        // Batch used 1 call; sequential used 1 more.
        XCTAssertEqual(provider.refreshCallCount, 2)
    }
}
