# ``SwiftResilience``

An offline-first async networking and task orchestration framework for iOS,
built on Swift Concurrency and URLSession.

## Overview

SwiftResilience is a production-grade reliability layer for mobile apps.
Most apps face the same hard problems — flaky networks, duplicate requests,
background retry failures, offline action queues, and cancellation races.
This framework solves them one focused feature at a time.

The architecture is layered: each module depends only on what sits below it,
so every piece can be understood, tested, and explained in isolation.

---

## Changelog

### 8 Jun 2026 — Advanced Observability

**Files added:**
- `Observability/RequestEvent.swift`
- `Observability/RequestMetricsCollector.swift`
- `Tests/Observability/ObservabilityTests.swift`

**Files updated:**
- `Networking/AsyncRequestEngine.swift`

**What was built:**

A structured event emission layer that gives `AsyncRequestEngine` a full
view of every request's lifecycle — start, retry, success, failure, and
deduplication — without changing its public API.

`RequestEvent` is a `Sendable` enum with five cases, each carrying a
`traceID: UUID` that links all events for the same logical request.
`.started` fires before the first attempt. `.retryScheduled(attempt:delay:)`
fires after each retryable failure and before the sleep — `delay` tells the
sink how long the engine *will* wait rather than how long it has waited.
`.succeeded(statusCode:duration:attempt:)` fires on a 2xx response; `attempt`
is zero-based so callers can distinguish first-try successes from retried ones.
`.failed(error:attempt:)` fires when retries are exhausted or a non-retryable
error occurs — exactly one terminal event per `.started`. `.deduplicated`
fires when a second concurrent `send()` joins an in-flight task instead of
starting a new network call; it carries its own fresh `traceID` so the count
of coalesced call-sites is observable.

`RequestEventSink` is a one-method `Sendable` protocol
(`func record(_ event: RequestEvent) async`). The `async` signature means
actor sinks receive events on their own executor via transparent actor hopping
— no manual dispatching. Injected into `AsyncRequestEngine.init` as an
optional parameter defaulting to `nil`, so all existing callsites compile
unchanged. Zero overhead when nil: `eventSink?.record(...)` short-circuits
before any enum construction or actor hop.

`AsyncRequestEngine` was updated to accept the optional sink and emit events
at key points in `executeWithRetry`. `.started` is emitted at the top of
`executeWithRetry` (not in `send()`) to guarantee ordering: it always arrives
at the sink before `.retryScheduled`, `.succeeded`, and `.failed` because
those are emitted later in the same function. The task is registered in
`inFlightTasks` before any `await` so deduplication correctness is
unaffected by event emission.

`RequestMetricsCollector` is a `public actor` implementing `RequestEventSink`.
It accumulates five counters (`requestsStarted`, `requestsSucceeded`,
`requestsFailed`, `retriesScheduled`, `deduplicationsHit`) and a running
`totalSuccessDuration` sum. `snapshot() -> RequestMetrics` returns an
immutable `Sendable` struct copy of the current state — safe to read from any
context. `RequestMetrics` exposes two computed properties: `averageSuccessDuration`
(nil until at least one success) and `successRate` (`succeeded / (succeeded +
failed)`, nil until at least one completion; deduplication hits and in-progress
requests are excluded from the denominator). `reset()` zeroes all counters for
a new measurement window.

**Design decisions:**

- `.started` emitted inside `executeWithRetry`, not `send()` — this is the
  only location that has exclusive ordering over all subsequent events for the
  same request.
- `successRate` denominator excludes deduplication hits — a deduplicated caller
  made no network request, so counting it as a success would inflate the rate.
- `retryScheduled` fires before the sleep — lets custom sinks measure actual
  sleep duration by timestamping on `.retryScheduled` and the following attempt.
- Pull model for `RequestMetrics` (`snapshot()` on demand, no `AsyncStream`) —
  keeps the type dependency-free; apps wanting reactive updates can wrap in an
  `ObservableObject` and poll.

**Test coverage:**

Event sequence tests (via `CapturingEventSink` actor + mock sessions):
- Success path: 2 events, correct order, shared `traceID`, correct URL/method/
  statusCode/attempt.
- Retry then succeed: 3 events in order; `retryScheduled` carries `attempt: 0`
  and correct delay; `succeeded` carries `attempt: 1`; all share `traceID`.
- Non-retryable failure: `.started` then `.failed(attempt: 0)`.
- Retry exhausted: `.started`, `.retryScheduled`, `.failed(attempt: 1)`.
- Deduplication: exactly 1 `.started`, 1 `.deduplicated`, 1 `.succeeded`;
  `deduplicated` carries a distinct `traceID`; `session.callCount == 1`.

Metrics counter tests (direct `record()` calls — no engine or network):
- Each event type increments its counter only.
- Multi-request accumulation across all five counters.
- `reset()` zeroes all counters; new events after reset count independently.
- `averageSuccessDuration`: nil with no successes; equals single duration;
  returns correct mean for multiple successes.
- `successRate`: nil with no completions; 1.0 for all-succeeded; 0.0 for
  all-failed; 0.75 for 3 successes + 1 failure; deduplication hits and
  in-progress `.started` events excluded from denominator.

---

### 8 Jun 2026 — BGTaskScheduler Integration

**Files added:**
- `BackgroundQueue/BackgroundQueueProtocols.swift`
- `BackgroundQueue/BackgroundQueueDrainer.swift`
- `Tests/BackgroundQueue/BackgroundQueueDrainerTests.swift`

**What was built:**

A two-type integration layer that connects `OfflineQueueEngine` to iOS's
`BGTaskScheduler` so pending requests drain while the app is suspended.

The gap it fills: `OfflineQueueEngine` drains on connectivity events while the
app is foregrounded. If the device comes online while the app is backgrounded,
the drain loop is not running and queued requests sit on disk until the user
next opens the app. `BackgroundQueueDrainer` closes this by registering a
`BGProcessingTask` that iOS runs at the next suitable background opportunity.

`BackgroundTaskHandling` is an `AnyObject` protocol with two members —
`expirationHandler` and `setTaskCompleted(success:)` — that match `BGTask`'s
existing interface. `extension BGTask: BackgroundTaskHandling {}` is an empty
retroactive conformance, zero implementation needed.

`BackgroundTaskScheduling` is an `AnyObject` protocol with `register` and
`submit`. The `launchHandler` parameter uses `(any BackgroundTaskHandling) -> Void`
rather than `(BGTask) -> Void`. Bridging is provided by
`SystemBackgroundTaskScheduler` — a wrapper singleton around
`BGTaskScheduler.shared`. A retroactive extension on `BGTaskScheduler` was
rejected because its existing `register` overload (taking `(BGTask) -> Void`)
would create an ambiguous call site.

`BackgroundQueueDrainer` is the public integration type. `register()` must be
called before `application(_:didFinishLaunchingWithOptions:)` returns — iOS
silently ignores later registrations. `scheduleNextDrain()` submits a
`BGProcessingTaskRequest` with `requiresNetworkConnectivity = true` and
`requiresExternalPower = false`; call it from every
`sceneDidEnterBackground`/`applicationDidEnterBackground` transition.

`handleTask(_:)` installs the expiration handler synchronously before creating
the drain `Task` — no window where iOS could fire expiration with no handler.
The drain Task runs `OfflineQueueEngine.runDrainCycle()` and calls
`setTaskCompleted(success: true)` on completion. If iOS fires the expiration
handler first, `drainTask.cancel()` is called (cooperative — exits at the next
`guard !Task.isCancelled` checkpoint in the drain loop), then
`setTaskCompleted(success: false)`. `setTaskCompleted` is idempotent so
concurrent calls from both paths are safe.

All types are wrapped in `#if canImport(BackgroundTasks)` — the framework is
iOS/Mac Catalyst only.

**Design decisions:**

- `BGProcessingTask` was chosen over `BGAppRefreshTask` for its larger time
  budget (minutes vs ~30s) and configurable network requirement. A queue of
  pending requests involves N sequential network calls; the 30-second budget
  of `BGAppRefreshTask` risks expiration mid-drain.
- `SystemBackgroundTaskScheduler` wrapper (not a `BGTaskScheduler` extension)
  avoids an ambiguous `register` overload between the system's `(BGTask) -> Void`
  signature and our protocol's `(any BackgroundTaskHandling) -> Void`.
- `handleTask` uses a local `var drainTask: Task?` captured by reference in the
  expiration closure. Swift closures capture `var` by reference, so by the time
  the closure executes, `drainTask` is always non-nil.

**Test coverage:**
- `register()` records identifier and does not submit a task request.
- `scheduleNextDrain()` submits a `BGProcessingTaskRequest` with the correct
  identifier, `requiresNetworkConnectivity = true`, `requiresExternalPower = false`.
- Multiple `scheduleNextDrain()` calls each submit a request.
- `handleTask` installs `expirationHandler` synchronously (verified with no
  yield between fireHandler and assertion).
- Successful drain → `setTaskCompleted(success: true)` after 200ms.
- Expiration fires before drain Task runs → `setTaskCompleted(success: false)`.
- After expiration + 200ms, cancelled drain Task has not called
  `setTaskCompleted` a second time.

---

### 8 Jun 2026 — Concurrency Safety Layer

**Files added:**
- `ConcurrencySafety/TokenProvider.swift`
- `ConcurrencySafety/TokenRefreshCoordinator.swift`
- `ConcurrencySafety/AuthenticatedRequestEngine.swift`
- `Tests/ConcurrencySafety/TokenRefreshCoordinatorTests.swift`
- `Tests/ConcurrencySafety/AuthenticatedRequestEngineTests.swift`

**What was built:**

A transparent token injection and 401-refresh coordination layer built in three
focused types that compose on top of `AsyncRequestEngine`.

`TokenProvider` is the single integration point between SwiftResilience and the
consuming app's auth layer. The developer implements it once — typically in
their auth module — with two methods: `currentToken()` reads the current access
token from the app's token store (Keychain, in-memory cache, etc.) and must be
fast since it is called before every request; `refreshToken()` performs the
actual network call to exchange a refresh token for a new access token, persists
the result, and returns it. The protocol refines `Sendable` so implementations
that hold mutable state must be actors or otherwise thread-safe.

`TokenRefreshCoordinator` is an actor that wraps `TokenProvider` and guarantees
that `refreshToken()` is called at most once per expiry event regardless of how
many concurrent requests triggered a 401. The mechanism mirrors the
request-deduplication pattern already in `AsyncRequestEngine`: the first caller
finds `refreshTask == nil`, creates a `Task<String, Error>`, stores it
atomically (the actor boundary prevents two callers from both seeing `nil`), and
suspends at `await task.value`. All subsequent callers find the in-progress task
and await its cached value — no second network call. `defer { refreshTask = nil }`
clears the reference on completion so the next expiry cycle starts a fresh
refresh. Failures are also coalesced — every waiting caller receives the same
error, and the lifecycle resets so the next 401 can begin a new attempt.

`AuthenticatedRequestEngine` is an actor that wraps `AsyncRequestEngine` and
owns the retry orchestration: read `coordinator.currentToken()`, inject it as
`Authorization: Bearer <token>`, send, catch only 401, call
`coordinator.refresh()` (coalesced), retry once with the new token. If the
retry is also 401 the error propagates — the caller should redirect to login.
All non-401 errors are rethrown without touching the token lifecycle. The
private `AuthenticatedRequest<Wrapped>` adapter wraps any `NetworkRequest` and
merges the token into its `headers` dictionary; a new instance is created for
each attempt so the caller's original request is never mutated. Token header
name and prefix are configurable (`"Authorization"` / `"Bearer "` by default).

**Design decisions:**

- Refresh is reactive (on 401), not proactive (on expiry timestamp). Avoids
  clock-skew errors, over-refreshing of valid tokens, and the test complexity
  of mocking system clocks.
- `TokenRefreshCoordinator` delegates `currentToken()` to the provider rather
  than caching internally — the provider owns storage and knows when its value
  is stale.
- `send()` retries exactly once after refresh — a second 401 propagates
  immediately, no infinite loop.
- `TokenAwareSession` (in tests) drives correctness from the token value rather
  than call order, making concurrent tests fully deterministic.

**Test coverage:**
- `TokenRefreshCoordinator` — `currentToken` delegation and nil; single
  refresh returns correct token and calls provider once; sequential refreshes
  each start a fresh Task; failure propagates; retry after failure succeeds.
- `TokenRefreshCoordinator` concurrent — 5 concurrent `refresh()` calls with
  50ms delay coalesce into one provider call, all 5 receive the same token;
  concurrent failure propagates to all callers; sequential call after batch
  starts new refresh.
- `AuthenticatedRequestEngine` token injection — default `Authorization: Bearer`
  header; nil token sends without header; custom header name; custom prefix;
  existing request headers preserved.
- `AuthenticatedRequestEngine` 401 handling — 401 triggers one refresh and
  successful retry; second consecutive 401 throws without further refresh; 403
  rethrows without refresh; 500 rethrows without refresh; refresh error
  propagates to caller.
- `AuthenticatedRequestEngine` concurrency — 4 concurrent sends all get 401
  (old token), exactly one `refreshToken()` call fires, all 4 retries succeed
  (new token), total session calls = 8.

---

### 7 Jun 2026 — Offline Queue Engine

**Files added:**
- `OfflineQueue/QueueableRequest.swift`
- `OfflineQueue/QueueEntry.swift`
- `OfflineQueue/DiskQueueStore.swift`
- `OfflineQueue/ReachabilityMonitor.swift`
- `OfflineQueue/OfflineQueueEngine.swift`
- `Tests/OfflineQueue/QueueableRequestTests.swift`
- `Tests/OfflineQueue/QueueEntryTests.swift`
- `Tests/OfflineQueue/DiskQueueStoreTests.swift`
- `Tests/OfflineQueue/ReachabilityMonitorTests.swift`
- `Tests/OfflineQueue/OfflineQueueEngineTests.swift`

**What was built:**

A complete offline-first delivery layer built in five focused pieces, each
independently tested before the next was started.

`QueueableRequest` extends `NetworkRequest` with three properties the queue
needs: `ttl` (how long to keep the entry on disk), `priority` (drain ordering
weight), and `idempotencyKey` (stable fingerprint for server-side deduplication
on replay). All three have default implementations via a protocol extension so
conforming types require zero extra code in the common case. `QueuePriority` is
a `Comparable` enum with raw `Int` values (`normal = 0`, `high = 1`,
`critical = 2`) so sorted collections work without custom comparators.

`QueueEntry` is a `Codable`, `Equatable` struct — the unit of storage. It
snapshots every field of the request into primitive types (`method` as a raw
`String`, `priority` as a raw `Int`) rather than storing the protocol directly.
This sidesteps the existential-Codable problem and produces a stable, human-
readable JSON format that survives app updates and enum reorderings. A computed
`isExpired` property evaluates TTL on demand so `DiskQueueStore` never holds
stale state. `asURLRequest()` reconstructs the `URLRequest` and injects the
`Idempotency-Key` header at drain time.

`DiskQueueStore` is an actor that writes one JSON file per entry to
`Application Support/SwiftResilience/OfflineQueue/`. File-per-entry means
atomic writes and deletes — no global lock, no read-modify-write on a single
queue file. `save` overwrites on duplicate IDs (safe retry after a partial
write). `load` decodes all `.json` files, silently skips corrupt ones, filters
expired entries, and returns results sorted by priority descending then
`enqueuedAt` ascending (causal FIFO within a priority tier). `deleteExpired`
is a separate sweep called at the start of each drain cycle. `count` includes
expired entries so the `maxQueueSize` cap accounts for entries not yet swept.

`ReachabilityMonitoring` is an actor protocol exposing `isConnected: Bool` and
`connectivity: AsyncStream<Bool>`. `NetworkReachabilityMonitor` implements it
using `NWPathMonitor` on a private `DispatchQueue`. Path updates are dispatched
back onto the actor via an unstructured `Task` to keep actor isolation intact.
The monitor fires its handler immediately on `start(queue:)` so `isConnected`
reflects real state within one event-loop tick. The protocol boundary keeps
`OfflineQueueEngine` fully testable — `MockReachabilityMonitor` (in the test
target) is the controllable stand-in used throughout the engine tests.

`OfflineQueueEngine` is the main actor. It wires the three pieces above together
with `AsyncRequestEngine` into a two-path delivery model:

- **Fast path** — if `reachabilityMonitor.isConnected`, attempt an immediate
  `AsyncRequestEngine.send`. On success nothing is written to disk. On
  `.noConnection` or `.timedOut` the request falls through to the queue path.
  Any other error (4xx, cancellation) is rethrown directly — it signals a
  problem the server returned, not a connectivity gap, so queuing would not help.
- **Queue path** — `maxQueueSize` is enforced, the request is snapshotted into
  a `QueueEntry`, and written to `DiskQueueStore`.

The drain loop (started via `start()`) iterates `reachabilityMonitor.connectivity`
and calls `runDrainCycle()` on every `true` event. A cycle sweeps expired entries,
loads surviving entries in priority-FIFO order, and sends each through
`AsyncRequestEngine` via a private `QueueEntryRequest` adapter. Successfully
sent entries are deleted. A connectivity error during drain breaks the inner
loop — remaining entries stay on disk for the next reconnect. A server error
(4xx) deletes the entry — retrying a request the server actively rejected would
only waste bandwidth.

`OfflineQueueError.full` is thrown when `maxQueueSize` is exceeded. The caller
decides whether to discard the new request, cancel an existing lower-priority
entry, or surface an error to the user.

**Design decisions:**

- `QueueEntry` copies fields as primitives rather than storing `any NetworkRequest`
  — protocol existentials cannot be made `Codable` without a known concrete type.
- `idempotencyKey` default is a stable string fingerprint (`METHOD:url:base64body`)
  — `hashValue` was rejected because Swift does not guarantee hash stability across
  process launches, which would break server-side idempotency after an app restart.
- `runDrainCycle()` is `internal` (not `private`) so tests can invoke it directly
  without driving the reachability stream, making drain tests deterministic.
- `NWPathMonitor` cannot be controlled in unit tests. `NetworkReachabilityMonitor`
  has a compile-time conformance test only; behavioural testing requires a real
  device or integration test suite.

**Test coverage:**
- `QueuePriority` raw values, `Comparable` ordering, sort stability.
- `QueueableRequest` default TTL, default priority, idempotency key determinism,
  key differentiation across URL/method/body, custom override.
- `QueueEntry` field copying (including nil body), default vs injected UUID and
  timestamp, expiry logic (fresh / expired / zero TTL), `asURLRequest` reconstruction
  including `Idempotency-Key` injection, `Codable` round-trip, `Equatable`.
- `DiskQueueStore` directory creation, save/overwrite/multi-file, load (empty /
  round-trip / expired filtered / priority sort / FIFO sort / corrupt file skipped /
  non-JSON ignored), delete (target only / no-op for missing ID), `deleteExpired`
  (removes only expired / returns count / no-op on empty), `count` (zero / reflects
  files / includes expired / decreases after delete).
- `MockReachabilityMonitor` protocol conformance, initial state, `setConnected`
  updates, stream delivery (single value / multiple in order / finish terminates).
- `OfflineQueueEngine` enqueue fast path (success / 4xx rethrown / connectivity
  error falls to disk), enqueue offline (disk write / field preservation), size cap,
  cancel (removes entry / no-op for missing ID), drain cycle (success + delete /
  expired deleted without send / connectivity error leaves entry / server error
  deletes entry / `Idempotency-Key` header present), drain ordering (priority
  descending / FIFO within same priority).

---

### 28 May 2026 — Request Deduplication

**Files added:**
- `Networking/RequestIdentity.swift`

**Files updated:**
- `Networking/AsyncRequestEngine.swift`
- `Tests/Networking/AsyncRequestEngineTests.swift`

**What was built:**

If two parts of the app call `send(_:)` with the same request at the same time,
the engine now fires the network call only once and delivers the result to both
callers when it completes. This prevents redundant bandwidth usage and duplicate
side effects on the server side.

`RequestIdentity` is an internal `Hashable` struct that captures the url, method,
headers, and body of a request. Timeout is excluded — two calls to the same
endpoint with different timeouts are still the same request from a deduplication
standpoint. This struct is the dictionary key.

`AsyncRequestEngine` now holds a private `inFlightTasks` dictionary mapping
`RequestIdentity` to a `Task<(Data, HTTPURLResponse), Error>`. When `send(_:)` is
called, it checks whether a task for that identity already exists. If it does, it
awaits the existing task's value directly — no new network call. If not, it creates
a task, stores it, and defers its removal once the task settles. Because the engine
is an actor, the dictionary check and the task insertion happen atomically (before
any `await`), so there is no window for two callers to race past the check and each
create their own task.

The retry loop was extracted into a private `executeWithRetry` method to keep the
deduplication logic in `send` easy to read.

**Test coverage:**
- Three concurrent identical requests result in exactly one network call, and all
  three callers receive the same response.
- Two concurrent requests to different URLs each trigger their own network call.

---

### 28 May 2026 — Async Request Engine

**Files added:**
- `Networking/HTTPMethod.swift`
- `Networking/NetworkRequest.swift`
- `Networking/NetworkError.swift`
- `Networking/NetworkSession.swift`
- `Networking/AsyncRequestEngine.swift`
- `Tests/Networking/AsyncRequestEngineTests.swift`

**What was built:**

The core execution engine that drives every network request in the framework.
It wires together Swift Concurrency, URLSession, and the RetryPolicy introduced
in the first commit into a single, coherent async loop.

`HTTPMethod` is a typed enum (GET, POST, PUT, PATCH, DELETE) rather than a raw
string so the compiler catches typos and switch statements over it are exhaustive.

`NetworkRequest` is a protocol, not a struct. This allows each feature of a
consuming app to define its own concrete request type (e.g. `LoginRequest`,
`FetchUserRequest`), keeping URL construction and body encoding close to where
they belong. The protocol carries `url`, `method`, `headers`, `body`, and
`timeout`, with sensible defaults via a protocol extension so simple GET requests
need only declare a URL.

`NetworkError` is a typed error enum covering `.httpError(statusCode:data:)`,
`.noConnection`, `.timedOut`, `.cancelled`, and `.underlying`. It carries an
`isRetryable` computed property that encodes the retry decision rules:
5xx and 429 are retryable (transient server problems), 4xx (except 429) are
not (client errors won't be fixed by trying again), and cancellation is never
retried. This keeps the retry logic out of the engine loop — the engine just
asks the error whether to retry.

`NetworkSession` is a one-method protocol that `URLSession` conforms to via an
empty extension. The engine depends on this protocol rather than the concrete
`URLSession` class, which means tests can inject a `MockNetworkSession` that
returns canned responses instantly — no real network, no flakiness.

`AsyncRequestEngine` is an `actor`. It holds the session and an optional
`RetryPolicy` and exposes a single `send(_:)` method. The retry loop works as
follows: fire the request; on a 2xx response return immediately; on a retryable
error consult the policy for a delay — if the policy returns `nil` (retries
exhausted) throw, otherwise call `Task.sleep` and loop; on a non-retryable
error throw immediately. `Task.sleep` is used deliberately because it
participates in Swift's cooperative cancellation — if the parent Task is
cancelled mid-sleep, the sleep throws `CancellationError`, which the engine
converts to `NetworkError.cancelled` and propagates. This prevents ghost
requests firing after the caller has moved on. The engine is declared as an
`actor` (not a class or struct) because future features — request deduplication,
in-flight task tracking — will require a shared dictionary of active tasks, and
the actor boundary makes those additions data-race-safe by default.

**Test coverage:**
- Successful 200 response returns data and response object.
- A 401 Unauthorized throws immediately without consulting the retry policy.
- A persistent 503 exhausts the policy and throws after the expected number of
  total attempts (1 initial + maxRetries).
- A 503 followed by a 200 succeeds after exactly one retry.
- A `.noConnection` error with no policy throws after one attempt.
- A `.noConnection` error with a policy retries the expected number of times.
- A cancelled URLError maps to `NetworkError.cancelled` and is not retried.

---

### 28 May 2026 — Retry Policy (initial commit)

**Files added:**
- `Retry/RetryPolicy.swift`
- `Retry/ExponentialRetryPolicy.swift`
- `Tests/ExponentialRetryPolicyTests.swift`

**What was built:**

`RetryPolicy` is a protocol with a single method:
`delay(forAttempt attempt: Int) -> TimeInterval?`. It returns a wait duration
before the next attempt, or `nil` when retries are exhausted. Returning `nil`
instead of throwing makes the protocol composable — callers inspect the return
value rather than catching errors, keeping control flow simple.

`ExponentialRetryPolicy` implements the protocol using exponential backoff:
`delay = baseDelay × 2^attempt`. With the default `baseDelay` of 1.0 s and
`maxRetries` of 3, the delays are 1 s, 2 s, 4 s before the fourth attempt
returns `nil`. Exponential backoff reduces thundering-herd pressure on a
recovering server — if 1,000 clients all retry at the same fixed interval they
hit the server in a wave; staggered delays spread that load out.

**Test coverage:**
- Delays for attempts 0, 1, 2 match the formula (1, 2, 4 seconds).
- Attempt equal to `maxRetries` returns `nil`.

---

---

## Architecture layers

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

## Topics

### Observability

- ``RequestEvent``
- ``RequestEventSink``
- ``RequestMetrics``
- ``RequestMetricsCollector``

### Retry

- ``RetryPolicy``
- ``ExponentialRetryPolicy``

### Networking

- ``HTTPMethod``
- ``NetworkRequest``
- ``NetworkError``
- ``AsyncRequestEngine``

### Concurrency Safety

- ``TokenProvider``
- ``TokenRefreshCoordinator``
- ``AuthenticatedRequestEngine``

### Background Queue

- ``BackgroundTaskHandling``
- ``BackgroundTaskScheduling``
- ``SystemBackgroundTaskScheduler``
- ``BackgroundQueueDrainer``

### Offline Queue

- ``QueueableRequest``
- ``QueuePriority``
- ``QueueEntry``
- ``DiskQueueStore``
- ``ReachabilityMonitoring``
- ``NetworkReachabilityMonitor``
- ``OfflineQueueEngine``
- ``OfflineQueueError``
