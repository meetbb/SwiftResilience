//
//  RequestMetricsCollector.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 08/06/26.
//

import Foundation

// MARK: - RequestMetrics

/// A point-in-time snapshot of request metrics collected by
/// `RequestMetricsCollector`.
///
/// `RequestMetrics` is a value type — callers receive an immutable copy of
/// the collector's state at the moment `snapshot()` was called. Subsequent
/// requests do not affect a previously obtained snapshot.
///
/// ## Computed properties
///
/// Two derived values are computed on demand rather than stored, so they
/// always reflect the snapshot's raw counters:
///
/// - `averageSuccessDuration` — mean wall-clock time for successful requests.
///   `nil` until at least one success has been recorded.
/// - `successRate` — ratio of successes to completed requests (successes +
///   failures). `nil` until at least one request has completed either way.
///   Deduplicated and in-progress requests are excluded from this figure.
public struct RequestMetrics: Sendable {

    // MARK: - Counters

    /// Number of unique requests that reached the network (`.started` events).
    /// Deduplicated callers are not counted here — see `deduplicationsHit`.
    public let requestsStarted: Int

    /// Number of requests that received a 2xx response (`.succeeded` events).
    public let requestsSucceeded: Int

    /// Number of requests that exhausted their retry budget or encountered a
    /// non-retryable error (`.failed` events).
    public let requestsFailed: Int

    /// Number of retry delays scheduled across all requests
    /// (`.retryScheduled` events). A single request that retried three times
    /// contributes 3 to this counter.
    public let retriesScheduled: Int

    /// Number of `send()` calls that joined an already-in-flight request
    /// instead of starting a new network call (`.deduplicated` events).
    public let deduplicationsHit: Int

    // Internal accumulator used to compute averageSuccessDuration.
    // Not exposed publicly — callers use the computed property instead.
    let totalSuccessDuration: TimeInterval

    // MARK: - Derived metrics

    /// Mean wall-clock duration of successful requests, in seconds.
    ///
    /// Measured from just before the first network attempt to the moment a
    /// 2xx response is received. Retried requests include all retry delays
    /// in their duration.
    ///
    /// Returns `nil` if no successful requests have been recorded yet.
    public var averageSuccessDuration: TimeInterval? {
        guard requestsSucceeded > 0 else { return nil }
        return totalSuccessDuration / TimeInterval(requestsSucceeded)
    }

    /// Ratio of successful requests to all completed requests.
    ///
    /// Completed means either succeeded or failed — in-progress and
    /// deduplicated requests are not included in this calculation.
    ///
    /// Returns `nil` if no requests have completed yet.
    public var successRate: Double? {
        let completed = requestsSucceeded + requestsFailed
        guard completed > 0 else { return nil }
        return Double(requestsSucceeded) / Double(completed)
    }
}

// MARK: - RequestMetricsCollector

/// An actor that implements `RequestEventSink` and accumulates structured
/// request metrics from `AsyncRequestEngine`.
///
/// Inject a `RequestMetricsCollector` when creating the engine, then call
/// `snapshot()` at any time to read a thread-safe copy of the current stats:
///
/// ```
/// let metrics = RequestMetricsCollector()
///
/// let engine = AsyncRequestEngine(
///     retryPolicy: ExponentialRetryPolicy(),
///     eventSink: metrics
/// )
///
/// // … send some requests …
///
/// let stats = await metrics.snapshot()
/// print("Success rate: \(stats.successRate.map { "\($0 * 100)%" } ?? "n/a")")
/// print("Avg duration: \(stats.averageSuccessDuration.map { "\($0)s" } ?? "n/a")")
/// ```
///
/// ## Resetting
///
/// Call `reset()` to zero all counters — useful when switching between app
/// sessions or clearing stats for a new measurement window.
///
/// ## Thread safety
///
/// `RequestMetricsCollector` is an actor. All mutation happens on its own
/// executor; `snapshot()` and `reset()` are safe to call from any context.
public actor RequestMetricsCollector: RequestEventSink {

    // MARK: - Private state

    private var _requestsStarted:     Int          = 0
    private var _requestsSucceeded:   Int          = 0
    private var _requestsFailed:      Int          = 0
    private var _retriesScheduled:    Int          = 0
    private var _deduplicationsHit:   Int          = 0
    private var _totalSuccessDuration: TimeInterval = 0

    // MARK: - Initialisation

    public init() {}

    // MARK: - RequestEventSink

    /// Updates the internal counters for the given event.
    ///
    /// Called by `AsyncRequestEngine` on the engine's actor executor; this
    /// method runs on the collector's own executor via actor hopping.
    /// Callers never need to call this directly.
    public func record(_ event: RequestEvent) {
        switch event {
        case .started:
            _requestsStarted += 1

        case let .succeeded(_, _, duration, _):
            _requestsSucceeded     += 1
            _totalSuccessDuration  += duration

        case .failed:
            _requestsFailed += 1

        case .retryScheduled:
            _retriesScheduled += 1

        case .deduplicated:
            _deduplicationsHit += 1
        }
    }

    // MARK: - Public API

    /// Returns an immutable snapshot of the current metrics.
    ///
    /// The snapshot is a value type — it reflects the state of the collector
    /// at the instant this method is called and is unaffected by subsequent
    /// requests.
    public func snapshot() -> RequestMetrics {
        RequestMetrics(
            requestsStarted:      _requestsStarted,
            requestsSucceeded:    _requestsSucceeded,
            requestsFailed:       _requestsFailed,
            retriesScheduled:     _retriesScheduled,
            deduplicationsHit:    _deduplicationsHit,
            totalSuccessDuration: _totalSuccessDuration
        )
    }

    /// Resets all counters to zero.
    ///
    /// Useful for clearing stats between measurement windows or test runs.
    /// Any in-flight requests that emit events after `reset()` is called will
    /// be counted in the new window.
    public func reset() {
        _requestsStarted     = 0
        _requestsSucceeded   = 0
        _requestsFailed      = 0
        _retriesScheduled    = 0
        _deduplicationsHit   = 0
        _totalSuccessDuration = 0
    }
}
