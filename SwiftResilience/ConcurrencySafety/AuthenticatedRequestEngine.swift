//
//  AuthenticatedRequestEngine.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 08/06/26.
//

import Foundation

// MARK: - AuthenticatedRequest (private adapter)

/// Wraps any `NetworkRequest` and injects an `Authorization` header, leaving
/// all other fields untouched.
///
/// A new instance is created for each send attempt so the caller's original
/// request object is never mutated — one with the current token for the initial
/// try, and a second with the refreshed token on retry.
private struct AuthenticatedRequest<Wrapped: NetworkRequest>: NetworkRequest {
    private let wrapped: Wrapped
    private let headerName: String
    private let headerValue: String?   // nil when the user is not authenticated

    var url: URL              { wrapped.url }
    var method: HTTPMethod    { wrapped.method }
    var body: Data?           { wrapped.body }
    var timeout: TimeInterval { wrapped.timeout }

    /// Merges the auth header into the wrapped request's existing headers.
    /// When `headerValue` is `nil` (no current token), the original headers
    /// are returned unchanged — no `Authorization` key is inserted.
    var headers: [String: String] {
        var h = wrapped.headers
        if let value = headerValue {
            h[headerName] = value
        }
        return h
    }

    init(wrapping base: Wrapped, headerName: String, headerValue: String?) {
        self.wrapped     = base
        self.headerName  = headerName
        self.headerValue = headerValue
    }
}

// MARK: - AuthenticatedRequestEngine

/// A drop-in replacement for `AsyncRequestEngine` that adds automatic token
/// injection and transparent 401-driven token refresh.
///
/// ## Request flow
///
/// 1. Read the current access token from `TokenRefreshCoordinator.currentToken()`.
/// 2. Inject it into the request's `Authorization` header
///    (format: `<tokenPrefix><token>`, default `"Bearer <token>"`).
/// 3. Send through the underlying `AsyncRequestEngine`.
/// 4. On **401 Unauthorized**:
///    a. Call `coordinator.refresh()`. Concurrent 401 callers are coalesced into
///       a single `TokenProvider.refreshToken()` call by the coordinator.
///    b. Retry the original request once with the new token.
///    c. If the retry is also 401, throw — the caller should redirect to login.
/// 5. Any non-401 error is rethrown without touching the token lifecycle.
///
/// ## Concurrency safety
///
/// `AuthenticatedRequestEngine` is an `actor`. Any number of `send(_:)` calls
/// may run concurrently without data races. Token-refresh coalescing is
/// guaranteed by `TokenRefreshCoordinator` — this engine handles only the
/// retry orchestration on top.
///
/// ## Usage
///
/// ```swift
/// let engine = AuthenticatedRequestEngine(
///     coordinator: TokenRefreshCoordinator(provider: MyTokenProvider())
/// )
///
/// // Token injection and refresh are transparent — no auth code at call sites.
/// let (data, _) = try await engine.send(FetchPostsRequest())
/// let (data, _) = try await engine.send(CreateCommentRequest(body: body))
/// ```
public actor AuthenticatedRequestEngine {

    // MARK: - Configuration

    /// The HTTP header that receives the token. Default: `"Authorization"`.
    public let tokenHeaderName: String

    /// The prefix prepended to the token value. Default: `"Bearer "`.
    /// Note the trailing space — the final header value is `"\(prefix)\(token)"`.
    public let tokenPrefix: String

    // MARK: - Dependencies

    private let requestEngine: AsyncRequestEngine
    private let coordinator: TokenRefreshCoordinator

    // MARK: - Initialisation

    /// Creates an authenticated engine.
    ///
    /// - Parameters:
    ///   - requestEngine: The engine that performs network I/O. Defaults to a
    ///     fresh `AsyncRequestEngine` backed by `URLSession.shared`.
    ///   - coordinator: Owns the token lifecycle — reads the current token and
    ///     coalesces concurrent refresh calls into a single network request.
    ///   - tokenHeaderName: HTTP header name for the token.
    ///     Defaults to `"Authorization"`.
    ///   - tokenPrefix: String prepended to the token (e.g. `"Bearer "`).
    ///     Defaults to `"Bearer "`.
    public init(
        requestEngine: AsyncRequestEngine = AsyncRequestEngine(),
        coordinator: TokenRefreshCoordinator,
        tokenHeaderName: String = "Authorization",
        tokenPrefix: String = "Bearer "
    ) {
        self.requestEngine   = requestEngine
        self.coordinator     = coordinator
        self.tokenHeaderName = tokenHeaderName
        self.tokenPrefix     = tokenPrefix
    }

    // MARK: - Public API

    /// Sends a request with automatic token injection and 401-refresh-retry.
    ///
    /// Token handling is fully transparent — callers set request fields
    /// (URL, method, body, headers) without touching auth.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: The decoded response data and `HTTPURLResponse`.
    /// - Throws:
    ///   - `NetworkError.httpError(401, _)` if the retry after refresh also
    ///     returns 401, indicating a fully expired session.
    ///   - Any other `NetworkError` thrown by `AsyncRequestEngine`.
    ///   - Any error from `TokenProvider.refreshToken()` (e.g., expired
    ///     refresh token — the app should navigate to the login screen).
    @discardableResult
    public func send(_ request: some NetworkRequest) async throws -> (Data, HTTPURLResponse) {
        // --- Initial attempt with the current token ---
        let currentToken = await coordinator.currentToken()
        let firstAttempt = makeRequest(from: request, token: currentToken)

        do {
            return try await requestEngine.send(firstAttempt)

        } catch NetworkError.httpError(let code, _) where code == 401 {
            // Token expired. Ask the coordinator to refresh — concurrent callers
            // that also hit 401 are coalesced into this single Task.
            let newToken = try await coordinator.refresh()

            // Retry once with the freshly issued token. If this also returns
            // 401, the session is fully expired — let the error propagate.
            let retryAttempt = makeRequest(from: request, token: newToken)
            return try await requestEngine.send(retryAttempt)
        }
        // All non-401 errors (4xx, 5xx, .noConnection, .cancelled, etc.)
        // are rethrown directly — they do not trigger a token refresh.
    }

    // MARK: - Private helpers

    private func makeRequest<R: NetworkRequest>(from base: R, token: String?) -> AuthenticatedRequest<R> {
        let headerValue = token.map { "\(tokenPrefix)\($0)" }
        return AuthenticatedRequest(wrapping: base, headerName: tokenHeaderName, headerValue: headerValue)
    }
}
