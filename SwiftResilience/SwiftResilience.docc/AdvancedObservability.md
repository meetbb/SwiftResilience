# Advanced Observability

Structured request tracing, retry visualisation, and a metrics dashboard for
`AsyncRequestEngine`.

## Overview

Without observability, a networking layer is a black box. You know a request
was sent and whether it succeeded, but you cannot answer: how many requests
were retried today? What is the average latency for the checkout endpoint?
How many concurrent sends were served from in-flight deduplication instead of
hitting the network?

Advanced Observability answers these questions by giving `AsyncRequestEngine`
an event emission hook. At every significant moment in a request's lifecycle,
the engine calls a developer-supplied `RequestEventSink`. The sink can be
a log writer, an analytics client, or the built-in `RequestMetricsCollector`
— the engine does not care which.

---

## Types

### `RequestEvent`

A `Sendable` enum that describes one observable moment:

| Case | When emitted |
|------|-------------|
| `.started` | Before the first network attempt |
| `.retryScheduled` | After a retryable failure, before the sleep delay |
| `.succeeded` | When a 2xx response is received |
| `.failed` | When retries are exhausted or a non-retryable error occurs |
| `.deduplicated` | When a `send()` call joins an in-flight identical request |

Every case carries a `traceID: UUID` that links all events for the same
logical request. `.deduplicated` gets its own fresh `UUID` — distinct from
the canonical request's — so you can count how many call-sites were coalesced
into a single network round trip.

### `RequestEventSink`

A one-method `Sendable` protocol:

```swift
public protocol RequestEventSink: Sendable {
    func record(_ event: RequestEvent) async
}
```

Implement it with an `actor` (the natural choice for a counter or log buffer)
or any other `Sendable` type. The engine calls `record` via `await`, which
hops transparently to the sink's executor — no manual dispatching required.

### `RequestMetrics`

A `Sendable` value-type snapshot returned by `RequestMetricsCollector.snapshot()`.
Contains five raw counters plus two computed properties derived from them:

- `requestsStarted` — unique requests that reached the network
- `requestsSucceeded` — requests that received a 2xx response
- `requestsFailed` — requests that terminated with an error
- `retriesScheduled` — total retry delays across all requests
- `deduplicationsHit` — `send()` calls served from an in-flight task
- `averageSuccessDuration` — mean wall-clock time for successful requests;
  `nil` until at least one success is recorded
- `successRate` — `succeeded / (succeeded + failed)`; `nil` until at least
  one request completes; deduplicated and in-progress requests are excluded
  from the denominator

### `RequestMetricsCollector`

The built-in concrete sink. An `actor` that accumulates counters as events
arrive and exposes an immutable `snapshot()` method that is safe to read from
any context.

```swift
let metrics = RequestMetricsCollector()

let engine = AsyncRequestEngine(
    retryPolicy: ExponentialRetryPolicy(),
    eventSink: metrics
)

// … send some requests …

let stats = await metrics.snapshot()
print("Requests:   \(stats.requestsStarted)")
print("Success:    \(stats.requestsSucceeded)")
print("Fail:       \(stats.requestsFailed)")
print("Retries:    \(stats.retriesScheduled)")
print("Deduped:    \(stats.deduplicationsHit)")
print("Avg dur:    \(stats.averageSuccessDuration.map { String(format: "%.3fs", $0) } ?? "n/a")")
print("Rate:       \(stats.successRate.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a")")
```

Call `reset()` to zero all counters and start a new measurement window.

---

## Event lifecycle diagrams

### First-try success

```
send()
  │
  └─ executeWithRetry()
         │
         ├─ .started
         │
         └─ session.data(for:) → 200
                │
                └─ .succeeded(attempt: 0)
```

### Retry then success

```
send()
  │
  └─ executeWithRetry()
         │
         ├─ .started
         │
         ├─ session.data(for:) → 503
         │      │
         │      └─ .retryScheduled(attempt: 0, delay: 1.0)
         │             │
         │             └─ Task.sleep(1.0s)
         │
         └─ session.data(for:) → 200
                │
                └─ .succeeded(attempt: 1)
```

### Non-retryable failure

```
send()
  │
  └─ executeWithRetry()
         │
         ├─ .started
         │
         └─ session.data(for:) → 401
                │
                └─ .failed(attempt: 0)
```

### Deduplication

```
send() — caller A                send() — caller B (same request)
  │                                │
  ├─ registers task               ├─ finds existing task
  │                               │
  └─ executeWithRetry()           └─ .deduplicated(traceID: freshUUID)
         │                               │
         ├─ .started                     │ (awaits A's task value)
         │                               │
         └─ .succeeded  ────────────────►│
```

---

## Ordering guarantees

Events for a single request arrive at the sink in lifecycle order:

1. `.started` is always first — emitted at the top of `executeWithRetry`,
   before the first network call.
2. `.retryScheduled` events arrive in attempt order, each followed by a
   sleep and the next attempt.
3. `.succeeded` or `.failed` is always last — exactly one terminal event
   per `.started`.

The `.deduplicated` event is independent of the canonical request's trace.
It has its own `traceID` and is not ordered relative to the canonical
request's events.

---

## Writing a custom sink

Any type that is `Sendable` and implements `func record(_ event: RequestEvent) async`
qualifies. A minimal structured logger:

```swift
actor RequestLogger: RequestEventSink {
    private let label: String

    init(label: String) { self.label = label }

    func record(_ event: RequestEvent) {
        switch event {
        case let .started(id, url, method):
            print("[\(label)] [\(id)] → \(method.rawValue) \(url.path)")

        case let .retryScheduled(id, attempt, delay):
            print("[\(label)] [\(id)] ↺ attempt \(attempt) failed, retry in \(delay)s")

        case let .succeeded(id, code, duration, attempt):
            print("[\(label)] [\(id)] ✓ \(code) after \(attempt + 1) attempt(s) in \(String(format: "%.3f", duration))s")

        case let .failed(id, error, attempt):
            print("[\(label)] [\(id)] ✗ \(error) after \(attempt + 1) attempt(s)")

        case let .deduplicated(id, url, _):
            print("[\(label)] [\(id)] = deduped \(url.path)")
        }
    }
}
```

---

## Integration with `AsyncRequestEngine`

The `eventSink` parameter is optional and defaults to `nil` — fully backward
compatible. Existing callsites compile unchanged.

```swift
// Before (still works)
let engine = AsyncRequestEngine(retryPolicy: ExponentialRetryPolicy())

// With observability
let metrics = RequestMetricsCollector()
let engine  = AsyncRequestEngine(
    retryPolicy: ExponentialRetryPolicy(),
    eventSink: metrics
)
```

Multiple sinks can be composed by writing a `MulticastEventSink` that
forwards `record` to an array of sinks — `AsyncRequestEngine` itself only
needs one.

---

## Test approach

Two complementary strategies keep the tests fast and deterministic.

**Event sequence tests** drive a real `AsyncRequestEngine` with mock sessions
and a `CapturingEventSink` actor. Because `executeWithRetry` `await`s each
`record()` call before proceeding, all events for a request are guaranteed to
be in the sink by the time `send()` returns. No `Task.sleep` polling needed.

**Metrics counter tests** inject crafted events directly into
`RequestMetricsCollector.record()` — no engine or network involved. This
makes counters fully deterministic (the duration in `.succeeded` is whatever
value the test supplies) and exercises the counter logic in isolation from the
engine.

---

## Design decisions

**Pull, not push.** `RequestMetrics` is obtained by calling `snapshot()` on
demand. There is no `AsyncStream<RequestMetrics>` or SwiftUI `@Published`
property. Apps that want reactive updates can wrap `RequestMetricsCollector`
in an `ObservableObject` and poll on a timer, keeping the core type
dependency-free.

**`successRate` excludes deduplication hits.** A `.deduplicated` caller did
not make a network request — counting it as a success would inflate the rate
artificially. The denominator is `succeeded + failed` only.

**`retryScheduled` fires before the sleep.** This lets a custom sink measure
actual sleep duration (by recording a timestamp on `.retryScheduled` and
another on the following `.started`-equivalent attempt) while keeping the
engine's event calls simple.

**Zero overhead when `eventSink` is `nil`.** All event emission paths are
guarded by `eventSink?. record(...)` — the optional short-circuits before any
enum construction or actor hop. Apps that do not need observability pay no
runtime cost.
