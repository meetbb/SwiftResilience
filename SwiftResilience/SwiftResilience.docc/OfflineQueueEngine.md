# Offline Queue Engine

Design specification and rationale for the SwiftResilience offline request queue.

## Purpose

The Offline Queue Engine is a persistence and replay layer for outbound network
requests. When a request cannot be delivered — because the device has no
connectivity, is in airplane mode, or is inside a tunnel — the engine serialises
that request to disk and automatically re-sends it once connectivity is restored.
The app's business logic fires the request and moves on; delivery is the
framework's responsibility.

---

## The Problem It Solves

Mobile apps run in environments that desktop software rarely encounters:

- Users open apps on the subway, in elevators, in rural areas, on international
  flights with patchy Wi-Fi.
- iOS aggressively suspends background processes, so in-memory retry queues
  evaporate.
- A user might tap "Submit Order", "Send Message", or "Post Review" while
  offline. Without a queue, that action silently disappears.

The failure modes without an offline queue are:

| Situation | Without queue | With queue |
|---|---|---|
| No connectivity at submission time | Request dropped, user must retry manually | Queued to disk, sent automatically later |
| App killed mid-retry | In-memory state lost | Queue survives; resumes on next launch |
| Flaky connection (partial loss) | Retry policy exhausts, gives up | Moved to offline queue, retried on reconnect |
| User goes offline, then online | Developer must write custom handling per feature | Framework handles it uniformly |

---

## Developer Ergonomics

Without this engine a developer faces a sprawl of one-off solutions:

```swift
// What every developer writes today — scattered across the codebase
func submitOrder(_ order: Order) async {
    do {
        try await api.post(order)
    } catch {
        // Now what? Save to UserDefaults? CoreData? Retry on next launch?
        // Who owns the retry? What if the app is killed?
        UserDefaults.standard.set(try? encoder.encode(order), forKey: "pendingOrder")
    }
}
```

With the Offline Queue Engine:

```swift
func submitOrder(_ order: Order) async throws {
    let request = SubmitOrderRequest(order: order)
    try await engine.enqueue(request)   // that's it — framework owns delivery
}
```

The framework provides:
- **Uniform API** — one `enqueue` call regardless of request type.
- **Automatic replay** — no `applicationDidBecomeActive` spaghetti.
- **Crash durability** — disk-backed, survives process death.
- **Zero per-feature code** — offline handling is not a feature concern.

---

## Internal Mechanisms

### 1 — Persistence Layer (Disk-Backed Queue)

Requests are serialised using `Codable` and written to a dedicated directory
inside the app's `Application Support` container. Each entry is a separate
JSON file named by a UUID so concurrent writes never collide and individual
entries can be deleted without rewriting the whole queue.

```
Application Support/
  SwiftResilience/
    OfflineQueue/
      3F2A1B4C-....json   ← one file per queued request
      9D8E7F6A-....json
```

Each file stores:

```json
{
  "id": "3F2A1B4C-...",
  "url": "https://api.example.com/orders",
  "method": "POST",
  "headers": { "Content-Type": "application/json" },
  "body": "...",
  "enqueuedAt": 1748476800,
  "ttl": 86400,
  "priority": 1
}
```

Disk was chosen over Core Data for the initial implementation because:
- No schema migrations to manage.
- Each request is independent — no relational joins.
- File-per-entry means atomic writes and deletes without locking.

### 2 — Network Reachability Monitor

An actor wraps `NWPathMonitor` (Network framework) and publishes connectivity
changes as an `AsyncStream<Bool>`. The drain loop subscribes to this stream and
wakes only when the path transitions from unsatisfied → satisfied. This is
purely event-driven — no polling, no timers, no battery waste.

```
NWPathMonitor
    └── path.status == .satisfied
            └── ReachabilityMonitor (actor)
                    └── AsyncStream<Bool>
                            └── OfflineQueueEngine.drainLoop()
```

### 3 — Queue Drain

When connectivity is restored the drain loop:

1. Reads all pending entries from disk, sorted by priority (descending) then
   `enqueuedAt` (ascending — oldest first within the same priority).
2. Filters out entries whose TTL has expired (they are deleted from disk).
3. Passes each surviving entry through `AsyncRequestEngine.send(_:)`, which
   applies the existing retry policy.
4. On success, deletes the entry file.
5. On failure (persistent network error), leaves the entry on disk for the
   next drain cycle.

Drain is sequential by default to avoid hammering a server that just came back
up. A `maxConcurrentDrainTasks` option (default: 1) will be exposed for
high-throughput use cases.

### 4 — Enqueue Path

When `enqueue(_:)` is called:

1. The engine first attempts an immediate send via `AsyncRequestEngine`.
2. If the send succeeds, nothing is written to disk — the common case is fast.
3. If the send fails with `NetworkError.noConnection` (or the device is already
   known to be offline via the reachability monitor), the request is serialised
   to disk.
4. Other errors (4xx, non-retryable) are thrown back to the caller — only
   connectivity failures are queued.

### 5 — Idempotency Contract

The offline queue replays requests that may have already partially reached the
server. Consumers are responsible for making mutations idempotent (e.g., using
a client-generated `Idempotency-Key` header). The engine will expose a
convenience method to attach a stable UUID key automatically.

---

## Performance Impact

### What the queue caches and what it does not

The Offline Queue Engine is an **outbound write queue** — it holds requests
waiting to be sent, not responses waiting to be read. It is not a response
cache. These are distinct concerns:

| Layer | What is stored | Direction | Purpose |
|---|---|---|---|
| Offline Queue | Serialised `NetworkRequest` | Outbound | Deliver mutations when offline |
| Response Cache *(future)* | Decoded server responses | Inbound | Serve reads without network |

The queue does not directly improve read latency. Its performance contribution
is reliability and perceived responsiveness:

- **Perceived responsiveness** — the app accepts user input immediately and
  acknowledges it locally. The round-trip to the server happens in the
  background. The user is not blocked.
- **Reduced error surface** — without the queue, connectivity failures bubble
  up as errors that UI must handle. With the queue, transient failures are
  invisible to the user.
- **Battery and bandwidth efficiency** — drain fires once on reconnect rather
  than polling continuously. Deduplication (already in `AsyncRequestEngine`)
  prevents the same request from being sent twice if it arrives while a drain
  is in progress.

---

## TTL (Time-To-Live)

Every queued entry carries a `ttl` field (seconds). On drain, the engine
computes `now - enqueuedAt` and discards entries where that delta exceeds `ttl`.

**Why TTL matters for a write queue:**

A request queued too long ago may be semantically stale even if the network is
now available. Consider:
- A "start live stream" request queued 3 hours ago should not be replayed.
- A "send message" queued 30 minutes ago almost certainly should be.

**Default TTL values:**

| Request category | Suggested TTL | Rationale |
|---|---|---|
| Durable mutations (orders, posts) | 7 days (604 800 s) | User intent is long-lived |
| Ephemeral actions (status updates) | 1 hour (3 600 s) | Stale after context changes |
| Time-sensitive actions (live events) | 5 minutes (300 s) | Useless after event ends |
| Default (not specified) | 24 hours (86 400 s) | Safe conservative default |

TTL is set per-request by the consumer via a protocol property on
`QueueableRequest`, with the 24-hour default applied via protocol extension.
The engine does not enforce a global maximum — that is a product decision.

**Expired entry handling:**

Expired entries are deleted silently from disk during the drain scan. A
delegate callback (`offlineQueue(_:didExpire:)`) will be available so the app
can surface an in-app notification if needed ("Your draft couldn't be sent
because too much time passed").

---

## Eviction and Ordering Strategy

### The queue is NOT an LRU cache

LRU (Least Recently Used) is a *read cache* eviction strategy: it discards the
entry accessed least recently to make room for new entries. It answers the
question: *"which cached response can I afford to forget?"*

The Offline Queue holds *write intentions*, not cached data. Discarding an entry
means the user's action is permanently lost, which is never acceptable based on
access frequency alone. LRU is the wrong model here.

### Actual eviction rules (in priority order)

1. **TTL expiry** — entry age exceeds its declared TTL. Deleted during drain
   scan. This is the primary and only automatic discard mechanism.
2. **Explicit cancellation** — the consumer calls `cancel(id:)` with the
   entry's UUID to remove a specific pending request (e.g., user deletes a
   draft before it is sent).
3. **Queue size cap** — if the queue exceeds a configurable `maxQueueSize`
   (default: 500 entries), new enqueue calls throw `OfflineQueueError.full`
   rather than silently evicting old entries. The consumer decides whether to
   drop the new request or cancel an existing one.

### Drain ordering strategy

Within a drain cycle, entries are ordered by:

1. **Priority** (higher first) — consumer-assigned integer (0 = normal,
   1 = high, 2 = critical).
2. **`enqueuedAt`** (older first within same priority) — FIFO preserves causal
   ordering. An "edit post" queued after a "create post" must not be sent first.

This is a **priority FIFO** model, which is the correct strategy for a write
queue where causal order within a resource matters.

---

## Summary

| Question | Answer |
|---|---|
| What does it do? | Persists outbound requests to disk and replays them on reconnect |
| Why is it necessary? | iOS kills in-memory state; users act offline; apps need durable delivery |
| What problem does it solve? | Dropped user actions, per-feature offline boilerplate, crash data loss |
| Developer benefit | Single `enqueue` call replaces all custom offline handling |
| Internal mechanism | Disk-backed JSON queue + NWPathMonitor + drain loop through AsyncRequestEngine |
| Performance benefit | Perceived responsiveness, reduced error surface, efficient drain |
| TTL | Per-request, default 24 h; expired entries deleted on drain |
| Eviction strategy | Priority FIFO with TTL expiry — NOT LRU (LRU is for read caches) |
