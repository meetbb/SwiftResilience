# SwiftResilience

**Offline-first async networking and resilience infrastructure for modern Swift applications.**

Mobile apps live in a hostile environment. Networks drop mid-request. Tokens expire in the middle of a burst of concurrent calls. The app backgrounds right when a queue of failed requests is waiting to drain. Users tap the same button three times because the first tap felt unresponsive.

SwiftResilience fixes these problems at the infrastructure level — before they reach your product code — using modern Swift Concurrency primitives (`actor`, `async`/`await`, `AsyncStream`, structured cancellation).

---

## What's inside

| Layer | What it solves |
|---|---|
| [Exponential Retry](#exponential-retry) | Transient failures and thundering-herd pressure |
| [Async Request Engine](#async-request-engine) | Cancellation-aware execution and typed errors |
| [Request Deduplication](#request-deduplication) | Duplicate network calls from concurrent UI events |
| [Offline Queue](#offline-queue) | Requests that fail while the device is offline |
| [Background Queue Drainer](#background-queue-drainer) | Draining the offline queue while the app is suspended |
| [Concurrency Safety](#concurrency-safety) | Token injection and coalesced 401 refresh |
| [Advanced Observability](#advanced-observability) | Structured event tracing and a metrics dashboard |

Every layer is independently testable and can be adopted incrementally. Start with retry policies, add deduplication later, layer in the offline queue when you need it.

---

## Requirements

- iOS 16+ / macOS 13+
- Swift 5.9+
- Xcode 15+

---

## Exponential Retry

**The problem:** A 503 from a briefly overloaded server is not a bug — it is an invitation to try again. But if 10,000 clients all retry at the same fixed interval, they hit the server in a wave and make the situation worse.

SwiftResilience uses exponential backoff: each retry waits `baseDelay × 2^attempt` seconds, spreading load across a widening window.

```swift
let policy = ExponentialRetryPolicy(
    maxRetries: 3,    // up to 3 retries after the initial attempt
    baseDelay: 1.0    // delays: 1s, 2s, 4s
)
```

`RetryPolicy` is a protocol, so you can plug in any strategy — fixed interval, jitter, circuit breaker — without touching the engine.

---

## Async Request Engine

**The problem:** URLSession errors are untyped `Error` values. Deciding whether to retry a `.notConnectedToInternet` vs a `401 Unauthorized` requires string-matching error codes. Cancellation is easy to miss, leaving ghost requests running after the caller has moved on.

`AsyncRequestEngine` wraps URLSession in a concurrency-safe `actor` with typed errors and cooperative cancellation baked in.

```swift
// Define your request
struct FetchUserRequest: NetworkRequest {
    let url: URL
    let method: HTTPMethod = .get
}

// Create the engine
let engine = AsyncRequestEngine(
    retryPolicy: ExponentialRetryPolicy(maxRetries: 3, baseDelay: 1.0)
)

// Send — cancellation-aware, typed errors
do {
    let (data, response) = try await engine.send(FetchUserRequest(url: userURL))
} catch NetworkError.noConnection {
    // show offline banner
} catch NetworkError.httpError(let statusCode, _) {
    // handle 4xx / 5xx
} catch NetworkError.cancelled {
    // caller cancelled — nothing to do
}
```

`NetworkError` carries an `isRetryable` property that encodes the retry rules: 5xx and 429 are retryable (transient server problems), 4xx are not (client errors won't be fixed by trying again), and `.cancelled` is never retried.

---

## Request Deduplication

**The problem:** A user pulls to refresh a feed while three background prefetches are already running for the same endpoint. Four identical network calls fire in parallel. The server processes all four; the app discards three responses.

`AsyncRequestEngine` detects concurrent calls to the same endpoint and coalesces them into a single in-flight `Task`. Every caller gets the response — only one network round trip is made.

```swift
// All three fire concurrently — only ONE network call is made.
// All three callers get the same response when it arrives.
async let feed1 = engine.send(FetchFeedRequest())
async let feed2 = engine.send(FetchFeedRequest())
async let feed3 = engine.send(FetchFeedRequest())

let (r1, r2, r3) = try await (feed1, feed2, feed3)
```

Deduplication is keyed on URL + method + headers + body. Two requests to the same URL with different bodies are treated as distinct.

---

## Offline Queue

**The problem:** A user submits a form while underground. The request fails with `.noConnection`. If you just show an error, the user has to find connectivity and re-submit. If you silently retry in the background, where do you store the request? How do you handle app restarts? How do you avoid replaying the same mutation twice?

`OfflineQueueEngine` answers all of this. It tries the fast path first (immediate send if connected), and falls back to a priority-sorted, disk-persisted queue when connectivity is unavailable.

```swift
// Your request conforms to QueueableRequest for TTL, priority, and idempotency
struct SubmitOrderRequest: QueueableRequest {
    let url: URL
    let method: HTTPMethod = .post
    var body: Data?

    // Keep this request on disk for up to 24 hours
    var ttl: TimeInterval { 86_400 }

    // Higher priority than default analytics events
    var priority: QueuePriority { .high }

    // Stable key — the server ignores duplicate deliveries with this key
    var idempotencyKey: String { "order-\(orderID)" }

    let orderID: String
}

let monitor = NetworkReachabilityMonitor()
let engine  = try OfflineQueueEngine(reachabilityMonitor: monitor)

// Start listening for connectivity events
Task { await monitor.start(); await engine.start() }

// Enqueue — succeeds immediately whether online or offline
try await engine.enqueue(SubmitOrderRequest(orderID: "abc-123", body: payload))
```

When connectivity returns, `OfflineQueueEngine` drains the queue automatically — highest priority first, FIFO within the same priority tier. Every replayed request carries an `Idempotency-Key` header so the server can safely deduplicate.

Persistence is file-per-entry JSON in `Application Support/SwiftResilience/OfflineQueue/`, so entries survive app restarts and are never lost in a single corrupt file.

---

## Background Queue Drainer

**The problem:** `OfflineQueueEngine` drains when connectivity returns *while the app is foregrounded*. But if the device comes back online while the app is suspended, the drain loop is not running. Queued requests sit on disk until the user next opens the app.

`BackgroundQueueDrainer` closes this gap by registering a `BGProcessingTask` with iOS. When iOS decides conditions are right — typically while the device is idle, connected, and not on critical battery — it wakes the app in the background and triggers a full drain cycle.

```swift
// AppDelegate.swift
let drainer = BackgroundQueueDrainer(
    taskIdentifier: "com.myapp.queue-drain",
    engine: offlineQueueEngine
)

func application(_ app: UIApplication,
                 didFinishLaunchingWithOptions options: ...) -> Bool {
    drainer.register()   // must be called before launch completes
    return true
}

func applicationDidEnterBackground(_ application: UIApplication) {
    drainer.scheduleNextDrain()   // tell iOS to grant background time
}
```

Also declare your task identifier in Info.plist:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.myapp.queue-drain</string>
</array>
```

The drainer handles expiration gracefully: if iOS reclaims background resources before the drain finishes, the in-progress cycle is cancelled cooperatively and iOS is notified with `setTaskCompleted(success: false)` — which prompts iOS to reschedule sooner.

---

## Concurrency Safety

**The problem:** Your auth token expires. Ten concurrent requests all receive a 401. Each one independently calls your refresh endpoint — ten refresh calls fire in parallel, ten new tokens are minted, nine are immediately thrown away. The eleventh call in the next millisecond gets a 401 on the new token because the race replaced it mid-flight.

`TokenRefreshCoordinator` coalesces all concurrent refresh attempts into one. The first caller fires the refresh; everyone else awaits its result. The refresh is guaranteed to happen exactly once per expiry event, no matter how many concurrent 401s trigger it.

```swift
// 1. Implement TokenProvider once in your auth module
actor KeychainTokenProvider: TokenProvider {
    func currentToken() async -> String? {
        Keychain.read("access_token")
    }

    func refreshToken() async throws -> String {
        let response = try await AuthAPI.refresh(
            using: Keychain.read("refresh_token")
        )
        Keychain.write("access_token", response.accessToken)
        return response.accessToken
    }
}

// 2. Wire it up
let provider    = KeychainTokenProvider()
let coordinator = TokenRefreshCoordinator(provider: provider)
let engine      = AuthenticatedRequestEngine(
    requestEngine: AsyncRequestEngine(),
    coordinator: coordinator
)

// 3. Send requests — token injection and 401 refresh are invisible to callers
let (data, _) = try await engine.send(FetchProfileRequest())
```

`AuthenticatedRequestEngine` injects `Authorization: Bearer <token>` before every request. On a 401, it triggers a coordinated refresh and retries exactly once. If the retry is also 401, the error propagates — the caller should redirect to login. All non-401 errors are rethrown without touching the token lifecycle.

```swift
do {
    let (data, _) = try await engine.send(FetchProfileRequest())
} catch NetworkError.httpError(401, _) {
    // Token is genuinely expired and refresh failed — redirect to login
    await showLoginScreen()
}
```

---

## Advanced Observability

**The problem:** Without instrumentation, your networking layer is a black box. You know a request was sent, but you cannot answer: what is the p95 latency for the checkout endpoint? How many requests were retried this session? How many concurrent sends were served from in-flight deduplication instead of hitting the network?

`AsyncRequestEngine` emits a structured `RequestEvent` at every significant moment in a request's lifecycle. Plug in any sink — a log writer, an analytics client, or the built-in `RequestMetricsCollector`.

```swift
let metrics = RequestMetricsCollector()

let engine = AsyncRequestEngine(
    retryPolicy: ExponentialRetryPolicy(),
    eventSink: metrics          // nil by default — zero overhead when unused
)

// … send some requests …

let stats = await metrics.snapshot()
print("Requests started: \(stats.requestsStarted)")
print("Succeeded:        \(stats.requestsSucceeded)")
print("Failed:           \(stats.requestsFailed)")
print("Retries:          \(stats.retriesScheduled)")
print("Deduped:          \(stats.deduplicationsHit)")
print("Avg duration:     \(stats.averageSuccessDuration.map { String(format: "%.3fs", $0) } ?? "n/a")")
print("Success rate:     \(stats.successRate.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a")")
```

Every event carries a `traceID: UUID` that links all events for the same logical request — start, each retry, and the terminal outcome. This makes it straightforward to correlate a slow request's retry timeline in a log stream.

You can also write a custom sink for any backend:

```swift
actor RequestLogger: RequestEventSink {
    func record(_ event: RequestEvent) {
        switch event {
        case let .started(id, url, method):
            print("[\(id)] → \(method.rawValue) \(url.path)")

        case let .retryScheduled(id, attempt, delay):
            print("[\(id)] ↺ attempt \(attempt) failed, retrying in \(delay)s")

        case let .succeeded(id, code, duration, attempt):
            print("[\(id)] ✓ \(code) in \(String(format: "%.3f", duration))s after \(attempt + 1) attempt(s)")

        case let .failed(id, error, attempt):
            print("[\(id)] ✗ \(error) after \(attempt + 1) attempt(s)")

        case let .deduplicated(id, url, _):
            print("[\(id)] = deduped \(url.path) — served from in-flight task")
        }
    }
}

let engine = AsyncRequestEngine(eventSink: RequestLogger())
```

---

## Architecture

Every layer sits on top of the one below it. Each one can be adopted independently — you do not need to use the offline queue to get retry policies, and you do not need the background drainer to use the concurrency safety layer.

```
┌─────────────────────────────────────┐
│        Consumer App / Demo          │
├─────────────────────────────────────┤
│     RequestMetricsCollector    ✓    │  actor — accumulates lifecycle counters
│     RequestEvent               ✓    │  Sendable enum — 5 observable moments
│     RequestEventSink           ✓    │  protocol — pluggable observability sink
├─────────────────────────────────────┤
│     AuthenticatedRequestEngine ✓    │  actor — token injection, 401 retry
│     TokenRefreshCoordinator    ✓    │  actor — coalesces concurrent refreshes
│     TokenProvider              ✓    │  protocol — app-supplied token lifecycle
├─────────────────────────────────────┤
│     BackgroundQueueDrainer     ✓    │  BGProcessingTask → runDrainCycle()
│     BackgroundTaskScheduling   ✓    │  protocol — abstracts BGTaskScheduler
│     BackgroundTaskHandling     ✓    │  protocol — abstracts BGTask
├─────────────────────────────────────┤
│     OfflineQueueEngine    ✓         │  actor — enqueue, drain, maxQueueSize
│     DiskQueueStore        ✓         │  actor — file-per-entry JSON persistence
│     ReachabilityMonitor   ✓         │  actor protocol + NWPathMonitor impl
│     QueueEntry            ✓         │  Codable snapshot — unit of storage
│     QueueableRequest      ✓         │  protocol — TTL, priority, idempotencyKey
├─────────────────────────────────────┤
│     AsyncRequestEngine    ✓         │  actor — requests, retry, deduplication
│     RequestIdentity       ✓         │  hashable key for in-flight task tracking
│     NetworkRequest        ✓         │  protocol — describes what to request
│     NetworkError          ✓         │  typed errors + isRetryable
│     NetworkSession        ✓         │  URLSession abstraction for testability
├─────────────────────────────────────┤
│     RetryPolicy           ✓         │  protocol — delay(forAttempt:)
│     ExponentialRetryPolicy ✓        │  baseDelay × 2^attempt
└─────────────────────────────────────┘
```

---

## Design principles

**Actor-first.** Every stateful type is an `actor`. There are no locks, no `DispatchQueue` wrappers, no `@objc` bridging. The Swift compiler enforces the invariants.

**Protocol-oriented testability.** Every system framework dependency (`URLSession`, `NWPathMonitor`, `BGTaskScheduler`, `BGTask`) is abstracted behind a protocol. Tests inject controllable fakes; production code uses the real implementations. No swizzling, no method interception.

**Zero-overhead opt-in.** Features that are not used cost nothing at runtime. Retry policy is `nil` by default. The event sink is `nil` by default. Optional chaining short-circuits before any allocation.

**Layered, not monolithic.** Each module has a clearly defined responsibility and depends only on what sits below it. You can read, test, and reason about each layer in isolation.
