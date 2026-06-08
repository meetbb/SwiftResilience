//
//  TokenProvider.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 08/06/26.
//

import Foundation

// MARK: - TokenProvider

/// The integration point between SwiftResilience and the consuming app's auth layer.
///
/// Implement this protocol once — typically in your app's auth module — to tell
/// `AuthenticatedRequestEngine` how to read and refresh your access token. Once
/// wired up, every outgoing request is automatically authenticated: no per-call
/// token handling required.
///
/// ## Responsibilities
///
/// - **`currentToken()`** — read the token from wherever your app stores it
///   (Keychain, in-memory cache, UserDefaults, etc.). This is called before
///   every request, so it must be fast. Return `nil` if the user is not
///   authenticated; the request will still be sent, just without an
///   `Authorization` header.
///
/// - **`refreshToken()`** — perform the network call that exchanges a refresh
///   token for a new access token. Persist the result before returning it so
///   that subsequent `currentToken()` calls return the fresh value. Throw if
///   the refresh fails so the caller can redirect the user to the login screen.
///
/// ## Token injection
///
/// `AuthenticatedRequestEngine` reads the value returned by `currentToken()`
/// and prepends the configured prefix (default: `"Bearer "`) before inserting
/// it into the `Authorization` header. Your implementation should return just
/// the raw token string — no prefix.
///
/// ## Thread safety
///
/// `TokenProvider` refines `Sendable`. Implementations that hold mutable state
/// (e.g., an in-memory token cache) must protect that state with an `actor`,
/// a lock, or a similar concurrency-safe mechanism.
///
/// ## Example
///
/// ```
/// actor KeychainTokenProvider: TokenProvider {
///     func currentToken() async -> String? {
///         Keychain.read("access_token")
///     }
///
///     func refreshToken() async throws -> String {
///         let response = try await AuthAPI.refresh(using: Keychain.read("refresh_token"))
///         Keychain.write("access_token", response.accessToken)
///         return response.accessToken
///     }
/// }
/// ```
public protocol TokenProvider: Sendable {

    /// Returns the current access token from cache.
    ///
    /// Called before every outgoing request. The value is injected into the
    /// `Authorization` header (after the configured prefix). Return `nil` when
    /// the user is not authenticated; the request will be sent without an auth
    /// header.
    func currentToken() async -> String?

    /// Performs a token refresh and returns the new access token.
    ///
    /// Called automatically by `TokenRefreshCoordinator` when a 401 response
    /// is received. Concurrent 401 callers are coalesced — this method is
    /// invoked exactly once regardless of how many requests triggered the 401.
    ///
    /// - Returns: The new access token. The implementation is responsible for
    ///   persisting it so that future `currentToken()` calls return it.
    /// - Throws: Any error from the refresh network call. The error is
    ///   propagated to every caller that was waiting for the refresh result.
    func refreshToken() async throws -> String
}
