//
//  RequestEvent.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 08/06/26.
//

import Foundation

// MARK: - RequestEvent

/// A discrete, observable moment in the lifecycle of a network request.
///
/// `AsyncRequestEngine` emits one or more `RequestEvent` values for every
/// logical request it handles. All events for a single logical request share
/// the same `traceID`, making it straightforward to correlate them in logs,
/// analytics pipelines, or debugging tools.
///
/// ## Lifecycle sequence
///
/// A request that succeeds on the first attempt emits:
/// ```
/// .started → .succeeded
/// ```
///
/// A request that is retried once before succeeding emits:
/// ```
/// .started → .retryScheduled(attempt: 0, …) → .succeeded
/// ```
///
/// A request that joins an already-in-flight identical request emits:
/// ```
/// .deduplicated
/// ```
/// No `.started` or `.succeeded` event is emitted for the deduplicated caller —
/// it shares the outcome of the canonical request.
///
/// ## Thread safety
///
/// `RequestEvent` is a value type that refines `Sendable`. It is safe to pass
/// across actor and task boundaries without copying or locking.
public enum RequestEvent: Sendable {

    /// Fired immediately before the first network attempt is made.
    ///
    /// - Parameters:
    ///   - traceID: Unique identifier for this logical request. All subsequent
    ///     events for the same request carry the same `traceID`.
    ///   - url: The request's fully-resolved URL.
    ///   - method: The HTTP verb (GET, POST, etc.).
    case started(traceID: UUID, url: URL, method: HTTPMethod)

    /// Fired when a request receives a 2xx response.
    ///
    /// - Parameters:
    ///   - traceID: Links this event to the matching `.started` event.
    ///   - statusCode: The HTTP status code (e.g., 200, 201, 204).
    ///   - duration: Wall-clock time from `.started` to this event, in seconds.
    ///   - attempt: Zero-based index of the attempt that succeeded. `0` means
    ///     the request succeeded on its first try; `1` means it succeeded after
    ///     one retry; and so on.
    case succeeded(traceID: UUID, statusCode: Int, duration: TimeInterval, attempt: Int)

    /// Fired when a request exhausts its retry budget or encounters a
    /// non-retryable error.
    ///
    /// - Parameters:
    ///   - traceID: Links this event to the matching `.started` event.
    ///   - error: The terminal `NetworkError` that caused the request to fail.
    ///   - attempt: Zero-based index of the attempt that failed terminally.
    case failed(traceID: UUID, error: NetworkError, attempt: Int)

    /// Fired when the engine decides to retry a request after a transient error.
    ///
    /// This event precedes the `Task.sleep` delay, so the `delay` parameter
    /// reflects how long the engine *will* wait, not how long it has already
    /// waited.
    ///
    /// - Parameters:
    ///   - traceID: Links this event to the matching `.started` event.
    ///   - attempt: Zero-based index of the attempt that just failed and
    ///     triggered this retry. Attempt `0` failed, so the engine will make
    ///     attempt `1` next.
    ///   - delay: Time in seconds the engine will sleep before the next attempt.
    case retryScheduled(traceID: UUID, attempt: Int, delay: TimeInterval)

    /// Fired when a second (or later) concurrent call to `send(_:)` joins an
    /// already-in-flight request instead of starting a new network call.
    ///
    /// The deduplicated caller shares the outcome of the canonical in-flight
    /// request. No `.started` event is emitted for it.
    ///
    /// - Parameters:
    ///   - traceID: A fresh `UUID` for this deduplicated call — distinct from
    ///     the canonical request's `traceID`. Useful for tracking how many
    ///     unique call-sites were served from a single network round trip.
    ///   - url: The request's URL (same as the canonical in-flight request).
    ///   - method: The HTTP verb (same as the canonical in-flight request).
    case deduplicated(traceID: UUID, url: URL, method: HTTPMethod)
}

// MARK: - RequestEventSink

/// Receives `RequestEvent` values emitted by `AsyncRequestEngine`.
///
/// Implement this protocol to plug any observability backend into the engine —
/// structured loggers, analytics pipelines, in-memory metrics stores, or
/// SwiftUI-friendly `ObservableObject` wrappers.
///
/// ## Thread safety
///
/// `RequestEventSink` refines `Sendable` because `AsyncRequestEngine` is an
/// actor. Implementations that hold mutable state (counters, log buffers, etc.)
/// must protect it with an `actor`, a lock, or a similar mechanism.
///
/// ## Example — minimal console logger
///
/// ```
/// actor ConsoleEventSink: RequestEventSink {
///     func record(_ event: RequestEvent) {
///         switch event {
///         case .started(let id, let url, let method):
///             print("[\(id)] → \(method.rawValue) \(url)")
///         case .succeeded(let id, let code, let duration, _):
///             print("[\(id)] ✓ \(code) in \(String(format: "%.3f", duration))s")
///         case .failed(let id, let error, _):
///             print("[\(id)] ✗ \(error)")
///         case .retryScheduled(let id, let attempt, let delay):
///             print("[\(id)] ↺ retry after attempt \(attempt), delay \(delay)s")
///         case .deduplicated(let id, let url, _):
///             print("[\(id)] = deduped \(url)")
///         }
///     }
/// }
/// ```
///
/// Then inject it when creating the engine:
///
/// ```
/// let engine = AsyncRequestEngine(eventSink: ConsoleEventSink())
/// ```
public protocol RequestEventSink: Sendable {

    /// Records a single event from the request lifecycle.
    ///
    /// Called by `AsyncRequestEngine` on its own actor executor. Implementations
    /// that are themselves actors will hop to their own executor transparently.
    ///
    /// - Parameter event: The event to record. Events for the same logical
    ///   request share a `traceID` and arrive in lifecycle order.
    func record(_ event: RequestEvent) async
}
