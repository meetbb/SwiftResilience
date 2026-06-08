//
//  TokenRefreshCoordinator.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 08/06/26.
//

import Foundation

// MARK: - TokenRefreshCoordinator

/// Coordinates token refresh calls across concurrent requests so that exactly
/// one refresh fires regardless of how many requests triggered a 401.
///
/// ## The problem
///
/// When an access token expires, several requests that are in flight
/// simultaneously all receive a 401. If each independently calls
/// `TokenProvider.refreshToken()` the result is:
///
/// - N redundant refresh network calls
/// - Race conditions on the token store (each refresh overwrites the previous)
/// - Some requests retrying with a stale token written by a slower refresh
///
/// ## The solution
///
/// `TokenRefreshCoordinator` uses the same task-coalescing pattern as
/// `AsyncRequestEngine`'s deduplication layer, applied to token refresh:
///
/// 1. The first 401 caller to reach `refresh()` starts a `Task` and stores a
///    reference to it in `refreshTask`.
/// 2. Any subsequent 401 caller finds the in-progress task and `await`s its
///    cached value directly — no second network call.
/// 3. When the task completes (success or failure), `defer` clears `refreshTask`
///    so the next 401 cycle starts a fresh refresh.
///
/// ## Actor safety
///
/// `TokenRefreshCoordinator` is an actor. The check-and-assignment of
/// `refreshTask` occurs before any `await`, so it is atomic with respect to
/// other callers on this actor — there is no window where two concurrent
/// callers both observe `refreshTask == nil` and each start their own refresh.
///
/// ## Usage
///
/// `TokenRefreshCoordinator` is an internal dependency of
/// `AuthenticatedRequestEngine`. You typically do not call it directly:
///
/// ```swift
/// let coordinator = TokenRefreshCoordinator(provider: MyTokenProvider())
/// let engine = AuthenticatedRequestEngine(coordinator: coordinator)
///
/// // Tokens are refreshed automatically on 401 — no manual calls needed.
/// try await engine.send(MyRequest())
/// ```
public actor TokenRefreshCoordinator {

    // MARK: - Private state

    private let provider: any TokenProvider

    /// The in-progress refresh task, if one exists.
    ///
    /// Holds a strong reference to the task until it settles, which is why
    /// late-arriving callers can still `await` its `.value` after the task
    /// has technically finished — `Task` caches its result for all awaiters.
    private var refreshTask: Task<String, Error>?

    // MARK: - Initialisation

    /// Creates a coordinator backed by the given token provider.
    ///
    /// - Parameter provider: The app-supplied token storage and refresh logic.
    ///   Typically injected once at app startup and shared for the lifetime of
    ///   the authenticated session.
    public init(provider: any TokenProvider) {
        self.provider = provider
    }

    // MARK: - Public API

    /// Returns the current access token without triggering a refresh.
    ///
    /// Delegates directly to `TokenProvider.currentToken()`. Called by
    /// `AuthenticatedRequestEngine` before every outgoing request to read the
    /// token that will be injected into the `Authorization` header.
    ///
    /// - Returns: The current token, or `nil` if the user is not authenticated.
    public func currentToken() async -> String? {
        await provider.currentToken()
    }

    /// Refreshes the access token, coalescing all concurrent callers into a
    /// single `TokenProvider.refreshToken()` call.
    ///
    /// - If no refresh is in flight, starts one and stores the task.
    /// - If a refresh is already running, returns the in-progress task's value
    ///   — no additional network call is made.
    /// - On completion (success or failure), clears `refreshTask` so the next
    ///   call starts a fresh refresh cycle.
    ///
    /// - Returns: The new access token.
    /// - Throws: The error from `TokenProvider.refreshToken()`, propagated to
    ///   all callers that were coalesced into this refresh attempt.
    public func refresh() async throws -> String {
        // If a refresh is already in flight, attach to it rather than starting
        // a second one. Task caches its result so all awaiters get the value
        // even if the task has already completed by the time they arrive.
        if let existing = refreshTask {
            return try await existing.value
        }

        // No refresh in flight — start one and register it so concurrent
        // callers that arrive while it is running can join instead of racing.
        let task = Task { [provider] in
            try await provider.refreshToken()
        }
        refreshTask = task

        // Clear the stored task once it settles (success or failure) so the
        // next 401 cycle begins a fresh refresh rather than reusing a stale task.
        defer { refreshTask = nil }

        return try await task.value
    }
}
