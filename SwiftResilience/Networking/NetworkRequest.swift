//
//  NetworkRequest.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import Foundation

/// Describes a single HTTP request — what to ask, not how to ask it.
///
/// This is intentionally a *protocol*, not a struct, for two reasons:
///
/// 1. **Separation of concerns** — callers define their own concrete
///    request types (e.g. `LoginRequest`, `FetchUserRequest`). Each one
///    carries its own URL and body encoding, keeping that logic out of
///    the engine.
///
/// 2. **Testability** — a protocol lets tests pass lightweight stubs
///    without constructing full URLRequests by hand.
///
/// `Sendable` is required because requests cross actor/task boundaries
/// when they're handed to `AsyncRequestEngine`.
public protocol NetworkRequest: Sendable {

    /// The fully-resolved URL for this request.
    var url: URL { get }

    /// The HTTP verb (GET, POST, etc.).
    var method: HTTPMethod { get }

    /// HTTP headers specific to this request.
    /// Merged on top of any session-level defaults inside the engine.
    var headers: [String: String] { get }

    /// The raw request body, if any.
    /// Callers are responsible for encoding (JSON, form-encoded, etc.)
    /// before returning data here.
    var body: Data? { get }

    /// Per-request timeout in seconds.
    /// Defaults to 30 s — override for long-running uploads or slow APIs.
    var timeout: TimeInterval { get }
}

// MARK: - Default implementations

public extension NetworkRequest {

    /// Most requests need no custom headers — avoid boilerplate.
    var headers: [String: String] { [:] }

    /// GET / DELETE requests carry no body.
    var body: Data? { nil }

    /// 30 seconds is the iOS URLSession default; explicit here for clarity.
    var timeout: TimeInterval { 30.0 }
}

// MARK: - Internal URLRequest conversion

extension NetworkRequest {

    /// Converts this protocol value into a Foundation `URLRequest`.
    ///
    /// Marked `internal` — this is a plumbing detail the engine uses.
    /// Consumers never need to call it directly.
    func asURLRequest() -> URLRequest {
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = method.rawValue
        urlRequest.httpBody   = body
        headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        return urlRequest
    }
}
