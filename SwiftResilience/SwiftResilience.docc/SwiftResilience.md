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

## Planned features

The following modules are planned in implementation order.
Each builds on the layer below it.

1. **Offline Queue Engine** — persists failed requests to disk and replays them
   when connectivity is restored. Requires a persistence layer (Core Data or
   file-backed queue) and a network reachability monitor.

3. **Concurrency Safety Layer** — token refresh coordination so that when an
   auth token expires, only one refresh fires regardless of how many concurrent
   requests triggered the 401, and all waiting requests resume with the new token.

4. **BGTaskScheduler Integration** — hooks into iOS background processing to
   drain the offline queue while the app is suspended.

5. **Advanced observability** — structured request tracing, retry visualisation,
   and a metrics dashboard (success/failure analytics).

---

## Architecture layers

```
┌─────────────────────────────────────┐
│        Consumer App / Demo          │
├─────────────────────────────────────┤
│     Offline Queue Engine            │  (planned)
├─────────────────────────────────────┤
│     Concurrency Safety Layer        │  (planned)
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

### Retry

- ``RetryPolicy``
- ``ExponentialRetryPolicy``

### Networking

- ``HTTPMethod``
- ``NetworkRequest``
- ``NetworkError``
- ``AsyncRequestEngine``
