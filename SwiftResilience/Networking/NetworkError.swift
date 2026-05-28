//
//  NetworkError.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import Foundation

/// All errors that can be produced by `AsyncRequestEngine`.
///
/// Using a typed enum instead of raw `Error` gives callers exhaustive
/// switch coverage and lets the engine make intelligent retry decisions
/// via `isRetryable` — without any string parsing or error code guessing.
public enum NetworkError: Error, Sendable {

    /// The server returned a non-2xx status code.
    /// The raw response body is attached so callers can parse error messages.
    case httpError(statusCode: Int, data: Data?)

    /// Device has no active network path.
    case noConnection

    /// The request exceeded its timeout interval.
    case timedOut

    /// The owning `Task` was cancelled before a response arrived.
    case cancelled

    /// Any Foundation / URLSession error not covered by the cases above.
    case underlying(any Error)
}

// MARK: - Retry decision

public extension NetworkError {

    /// Whether this error class is worth retrying.
    ///
    /// This is the bridge between `NetworkError` and `RetryPolicy`.
    /// The engine checks `isRetryable` *before* asking the policy for
    /// a delay — so a 401 Unauthorized never even consults the policy.
    ///
    /// **Rules:**
    /// - 5xx errors are server-side and often transient → retryable.
    /// - 429 Too Many Requests means the server asked us to back off → retryable
    ///   (the `RetryPolicy` delay gives it breathing room).
    /// - 4xx (except 429) are client errors; retrying won't fix them → not retryable.
    /// - No connection / timeout are network-layer blips → retryable.
    /// - Cancelled means the caller gave up intentionally → not retryable.
    var isRetryable: Bool {
        switch self {
        case .httpError(let statusCode, _):
            return statusCode >= 500 || statusCode == 429
        case .noConnection, .timedOut:
            return true
        case .cancelled:
            return false
        case .underlying:
            // Unknown errors: conservative — don't retry blindly.
            return false
        }
    }
}

// MARK: - URLError mapping

extension URLError {

    /// Converts a Foundation `URLError` into a typed `NetworkError`.
    ///
    /// Centralising the mapping here means the engine has one place to
    /// translate low-level codes rather than a scattered switch in every
    /// catch block.
    var asNetworkError: NetworkError {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost,
             .dataNotAllowed:
            return .noConnection
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        default:
            return .underlying(self)
        }
    }
}
