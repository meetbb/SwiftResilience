# Concurrency Safety Layer

Transparent token injection and 401-driven refresh coordination for concurrent
requests in `SwiftResilience`.

## Overview

Most authenticated apps share a single access token across many simultaneous
requests. When that token expires, several requests trigger a 401 at roughly
the same time. The naive response — each request independently refreshing the
token — produces a cascade of problems:

- **Redundant network calls** — N requests fire N refresh calls to the auth server.
- **Token store races** — each refresh overwrites the persisted token; the last
  write wins, but requests already past the write may hold a value from a
  previous iteration.
- **Stale-token retries** — a request that finishes its refresh slightly later
  than a sibling may retry with a token that the server has already invalidated.

The Concurrency Safety Layer eliminates all three problems with three focused
types that compose cleanly on top of `AsyncRequestEngine`.

---

## Types

### `TokenProvider`

The single integration point between `SwiftResilience` and the app's auth layer.
A developer implements this protocol once — typically in their auth module — to
tell the framework where tokens come from and how to get new ones.

```swift
actor KeychainTokenProvider: TokenProvider {
    func currentToken() async -> String? {
        Keychain.read("access_token")
    }

    func refreshToken() async throws -> String {
        let response = try await AuthAPI.refresh(using: Keychain.read("refresh_token"))
        Keychain.write("access_token", response.accessToken)
        return response.accessToken
    }
}
```

`currentToken()` is fast — it reads from whatever in-process store the app uses.
`refreshToken()` performs the actual network call and persists the result before
returning it.

### `TokenRefreshCoordinator`

An actor that wraps `TokenProvider` and guarantees that `refreshToken()` is
called at most once per expiry event, regardless of how many concurrent requests
triggered the 401.

The coalescing mechanism mirrors the request-deduplication pattern already used
in `AsyncRequestEngine`:

1. The first caller to reach `refresh()` finds `refreshTask == nil`, creates a
   `Task<String, Error>`, stores it, and suspends at `await task.value`.
2. Because `TokenRefreshCoordinator` is an actor, the check-and-store is atomic
   — no two callers can both see `nil` and each start their own task.
3. Every subsequent caller finds the in-progress task and suspends at
   `await existing.value` — no additional call to `provider.refreshToken()`.
4. When the task settles, all awaiters receive the same result. `Task` caches
   its value, so late arrivals get it instantly even if the task is already done.
5. `defer { refreshTask = nil }` clears the reference so the next expiry cycle
   starts fresh rather than re-using a completed task.

A refresh failure is also coalesced — every caller waiting on the same task
receives the same error, and the token lifecycle resets so the next 401 can
begin a new refresh attempt.

### `AuthenticatedRequestEngine`

An actor that replaces `AsyncRequestEngine` at call sites that require auth.
It owns the retry orchestration on top of `TokenRefreshCoordinator`:

1. Call `coordinator.currentToken()` and inject it as `Authorization: Bearer <token>`.
2. Send through the underlying `AsyncRequestEngine`.
3. On 401: call `coordinator.refresh()` (coalesced), then retry once with the
   new token.
4. If the retry is also 401, propagate the error — the app should redirect to
   the login screen.
5. All non-401 errors are rethrown directly without touching the token lifecycle.

The private `AuthenticatedRequest<Wrapped>` adapter wraps any `NetworkRequest`
and merges the token into its `headers` dictionary. A new instance is created
for each attempt (initial and retry), so the caller's original request object
is never mutated.

---

## Request flow

```
engine.send(request)
    │
    ├─ coordinator.currentToken()       ← fast, reads from cache
    │
    ├─ requestEngine.send(authedRequest)
    │       │
    │       ├─ 2xx  ────────────────────────────────── return (data, response) ✓
    │       │
    │       ├─ 401
    │       │    │
    │       │    └─ coordinator.refresh()             ← coalesced: fires once
    │       │            │                               regardless of N callers
    │       │            ├─ success: newToken
    │       │            │       │
    │       │            │       └─ requestEngine.send(retryRequest)
    │       │            │               │
    │       │            │               ├─ 2xx ──── return (data, response) ✓
    │       │            │               └─ 401 ──── throw NetworkError.httpError(401)
    │       │            │
    │       │            └─ failure ──────────────── throw (e.g. session expired)
    │       │
    │       └─ non-401 error ───────────────────────── rethrow (no refresh)
```

---

## Developer ergonomics

**Setup (once at app startup):**

```swift
let provider    = KeychainTokenProvider()
let coordinator = TokenRefreshCoordinator(provider: provider)
let engine      = AuthenticatedRequestEngine(coordinator: coordinator)
```

**Every call site (zero auth code):**

```swift
let (data, _) = try await engine.send(FetchUserRequest())
let (data, _) = try await engine.send(PostCommentRequest(body: body))
```

**On session expiry** (when `refreshToken()` throws or the retry also returns 401):

```swift
do {
    let (data, _) = try await engine.send(request)
} catch NetworkError.httpError(401, _) {
    navigateToLogin()
} catch {
    showError(error)
}
```

**Custom header or scheme:**

```swift
// API key in a custom header, no prefix:
let engine = AuthenticatedRequestEngine(
    coordinator: coordinator,
    tokenHeaderName: "X-API-Key",
    tokenPrefix: ""
)

// OAuth2 with "Token" scheme instead of "Bearer":
let engine = AuthenticatedRequestEngine(
    coordinator: coordinator,
    tokenPrefix: "Token "
)
```

---

## Why not refresh on every request?

`TokenProvider.currentToken()` is called before every request, but
`TokenProvider.refreshToken()` is only called when a 401 is received —
never preemptively. This design avoids:

- **Clock skew errors** — preemptive refresh based on an expiry timestamp can
  fire too early (due to clock differences between client and server) or fail
  to fire at all if the timestamp is stored incorrectly.
- **Over-refreshing** — many tokens have a rolling expiry; refreshing before
  expiry discards a still-valid token and resets the TTL unnecessarily.
- **Test complexity** — reactive refresh (on 401) is trivially testable with
  a mock session that returns a configured status code. Proactive refresh
  requires mocking system clocks.

The cost is one extra round-trip per expiry event. In practice, tokens last
minutes to hours; that round-trip is negligible.

---

## Test approach

`NWPathMonitor`-style concerns do not apply here — there is no system framework
to isolate. The test strategy is:

- `MockTokenProvider` — configurable stub that tracks `refreshCallCount` and
  supports a `refreshDelay` (nanoseconds) to force concurrent calls to overlap
  in time, making coalescing tests deterministic.
- `TokenAwareSession` — a `NetworkSession` mock that returns 200 when the
  `Authorization` header matches the expected valid token and 401 otherwise.
  Response correctness is driven by the token value, not call order, so
  concurrent tests have no sequencing dependencies.
- `TokenRefreshCoordinatorConcurrentTests` — fires N concurrent `refresh()`
  calls with a 50ms provider delay and asserts `refreshCallCount == 1`.
- `AuthenticatedRequestEngineConcurrencyTests` — fires N concurrent `send()`
  calls against `TokenAwareSession`. Initial attempts all 401 (old token);
  all retries succeed (new token). Asserts `refreshCallCount == 1` and total
  session calls == 2N.
