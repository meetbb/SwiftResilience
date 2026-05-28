//
//  AsyncRequestEngine.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import Foundation

/// The core execution engine of SwiftResilience.
///
/// Responsibilities:
/// 1. Convert a `NetworkRequest` into a `URLRequest` and fire it.
/// 2. Inspect the result — success, HTTP error, or network error.
/// 3. Consult `NetworkError.isRetryable` + `RetryPolicy` to decide whether
///    to wait and retry, or surface the error to the caller.
///
/// **Why `actor`?**
///
/// An `actor` serialises access to its stored properties, preventing data
/// races without manual locking. Right now the engine holds no mutable state,
/// but future features — request deduplication, in-flight task tracking,
/// circuit breaking — will require a shared dictionary. Establishing the
/// `actor` boundary now means those additions are safe by default.
///
/// **Why not `async` on the initialiser?**
///
/// Actors are initialised synchronously; the async work lives in `send(_:)`.
/// This keeps construction cheap and predictable.
public actor AsyncRequestEngine {

    // MARK: - Properties

    /// The session used to fire requests.
    /// Defaults to `.shared`; override in tests with a `MockNetworkSession`.
    private let session: any NetworkSession

    /// The retry policy applied when a retryable error occurs.
    /// `nil` means fail immediately — no retries.
    private let retryPolicy: (any RetryPolicy)?

    // MARK: - Initialisation

    public init(
        session: any NetworkSession = URLSession.shared,
        retryPolicy: (any RetryPolicy)? = nil
    ) {
        self.session     = session
        self.retryPolicy = retryPolicy
    }

    // MARK: - Public API

    /// Sends a network request, retrying on transient failures according
    /// to the configured `RetryPolicy`.
    ///
    /// - Parameter request: Any value conforming to `NetworkRequest`.
    /// - Returns: The raw response body and the HTTP metadata.
    /// - Throws: `NetworkError` — typed so callers can switch exhaustively.
    ///
    /// **Retry loop walkthrough (interview-ready explanation):**
    ///
    /// ```
    /// attempt = 0
    /// loop:
    ///   fire request
    ///   on success       → return
    ///   on retryable err → ask policy for delay(forAttempt: attempt)
    ///                       • policy returns nil  → we've hit maxRetries, throw
    ///                       • policy returns Xs   → Task.sleep(Xs), attempt++, continue
    ///   on permanent err → throw immediately (no policy consultation)
    /// ```
    ///
    /// `Task.sleep` is cooperative: if the parent `Task` is cancelled
    /// mid-sleep, it throws `CancellationError`, which we catch and
    /// rethrow as `.cancelled`. The caller's structured-concurrency tree
    /// collapses cleanly — no dangling timers.
    @discardableResult
    public func send(_ request: some NetworkRequest) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = request.asURLRequest()
        var attempt    = 0

        while true {

            // ── Step 1: Try the request ────────────────────────────────
            do {
                let (data, response) = try await session.data(for: urlRequest)

                // URLSession guarantees an HTTPURLResponse for HTTP(S) URLs,
                // but the return type is the base `URLResponse`. We cast to
                // confirm — an unexpected type is a framework bug, not a
                // user error, so we treat it as a permanent failure.
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.underlying(URLError(.badServerResponse))
                }

                // ── Step 2: Inspect the HTTP status code ──────────────
                if (200..<300).contains(httpResponse.statusCode) {
                    // Happy path — return immediately.
                    return (data, httpResponse)
                }

                // Non-2xx: wrap in a typed error so the retry logic below
                // can call `isRetryable` without knowing about HTTP status codes.
                let httpError = NetworkError.httpError(
                    statusCode: httpResponse.statusCode,
                    data: data
                )
                try await retryOrThrow(httpError, attempt: &attempt)

            } catch let networkError as NetworkError {
                // ── Step 3: Handle typed network errors ───────────────
                // These are thrown either by the `retryOrThrow` helper above
                // (permanent errors / exhausted retries) or by the URLError
                // mapping below. Re-throw them directly — they're already typed.
                throw networkError

            } catch {
                // ── Step 4: Map Foundation errors → NetworkError ──────
                // URLSession throws `URLError` for connection / timeout problems.
                // Everything else is wrapped in `.underlying` so callers always
                // deal with `NetworkError`, never raw Foundation types.
                let networkError = (error as? URLError)?.asNetworkError
                    ?? NetworkError.underlying(error)
                try await retryOrThrow(networkError, attempt: &attempt)
            }
        }
    }

    // MARK: - Private helpers

    /// Decides whether to sleep-and-continue or throw.
    ///
    /// Extracted into its own method so the main `send` loop stays readable.
    /// Uses `inout` on `attempt` to mutate the caller's counter in place —
    /// avoids returning a tuple just to thread state back.
    private func retryOrThrow(
        _ error: NetworkError,
        attempt: inout Int
    ) async throws {
        guard error.isRetryable,
              let delay = retryPolicy?.delay(forAttempt: attempt) else {
            // Either not retryable, or policy says we've exhausted all attempts.
            throw error
        }

        // Convert seconds → nanoseconds.
        // `Task.sleep(nanoseconds:)` works on Swift 5.5+.
        // On Swift 5.7+ you can write `Task.sleep(for: .seconds(delay))` instead.
        let nanoseconds = UInt64(delay * 1_000_000_000)

        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            // `Task.sleep` throws `CancellationError` if the owning Task is
            // cancelled mid-sleep. Convert to our typed error and propagate —
            // letting the loop continue after cancellation would be a bug.
            throw NetworkError.cancelled
        }

        attempt += 1
    }
}
