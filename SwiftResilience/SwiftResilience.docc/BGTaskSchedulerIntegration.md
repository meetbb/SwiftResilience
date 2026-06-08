# BGTaskScheduler Integration

Drains the offline request queue while the app is suspended using iOS's
`BGTaskScheduler` background processing framework.

## Overview

`OfflineQueueEngine` drains pending requests whenever the device reconnects to
the network while the app is foregrounded. But requests can be queued while the
app is active and then the app is backgrounded before connectivity returns. In
that case the drain loop is not running, and those requests sit on disk until
the user next opens the app.

`BackgroundQueueDrainer` closes this gap. It registers a `BGProcessingTask`
with iOS and submits a scheduling request each time the app enters the
background. When iOS decides conditions are right — typically while the device
is idle, has network connectivity, and is not on low battery — it wakes the app
in the background and calls the registered handler. The drainer runs a full
drain cycle and reports success back to iOS.

---

## Types

### `BackgroundTaskHandling`

An `AnyObject` protocol that abstracts `BGTask`:

```swift
var expirationHandler: (() -> Void)? { get set }
func setTaskCompleted(success: Bool)
```

`BGTask` already has both members, so `extension BGTask: BackgroundTaskHandling {}`
is an empty, zero-cost conformance. Tests inject a `MockBackgroundTask` that
records calls instead of talking to the system.

### `BackgroundTaskScheduling`

An `AnyObject` protocol that abstracts `BGTaskScheduler`:

```swift
func register(forTaskWithIdentifier:using:launchHandler:)
func submit(_:) throws
```

The `launchHandler` uses `(any BackgroundTaskHandling) -> Void` rather than
`(BGTask) -> Void`. This is why the production conformance is provided by a
wrapper class (`SystemBackgroundTaskScheduler`) rather than a retroactive
extension on `BGTaskScheduler` — extending `BGTaskScheduler` directly would
create an ambiguous overload between its existing `(BGTask) -> Void` method
and our protocol's `(any BackgroundTaskHandling) -> Void` method.

### `SystemBackgroundTaskScheduler`

The production singleton (`SystemBackgroundTaskScheduler.shared`). Wraps
`BGTaskScheduler.shared` and bridges the `BGTask` parameter to
`any BackgroundTaskHandling` in the launch handler closure. The bridge is a
single-line cast — `BGTask` already conforms to `BackgroundTaskHandling`.

### `BackgroundQueueDrainer`

The integration entry point. Holds an `OfflineQueueEngine` reference and an
injected `BackgroundTaskScheduling`. Exposes two public methods and one private
handler.

---

## Task execution flow

```
App enters background
    │
    └─ sceneDidEnterBackground
           │
           └─ drainer.scheduleNextDrain()
                  │
                  └─ BGProcessingTaskRequest (requiresNetworkConnectivity: true)
                         │
                         │   [iOS decides conditions are met]
                         │
                         ▼
               BGTaskScheduler fires handler
                         │
                         └─ BackgroundQueueDrainer.handleTask(task)
                                │
                                ├─ task.expirationHandler = { ... }   ← set first
                                │
                                └─ Task {
                                       await engine.runDrainCycle()
                                       │
                                       ├─ success → task.setTaskCompleted(success: true)
                                       └─ cancelled → return (expiration already called false)
                                   }
```

---

## Expiration handling

iOS may need to reclaim background resources before the drain finishes. The
drainer handles this in two steps:

1. **Install the expiration handler before any `await`** — there is no window
   where iOS could fire expiration with no handler registered.

2. **Cancel the drain Task, then call `setTaskCompleted(success: false)`** —
   cooperative cancellation sets a flag that `runDrainCycle` checks at each
   iteration boundary. The cycle stops at its next checkpoint rather than
   being forcibly killed mid-send.

`setTaskCompleted` is idempotent (iOS ignores calls after the first). So if
the drain Task finishes just as expiration fires, both paths call it, but only
the first one counts. The `guard !Task.isCancelled else { return }` check inside
the drain Task ensures the success call is skipped if cancellation already fired.

---

## App setup checklist

Before `BackgroundQueueDrainer` will work in production, the app needs two
pieces of configuration that SwiftResilience cannot do on its behalf:

**1. Info.plist — declare the task identifier:**

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.myapp.queue-drain</string>
</array>
```

iOS silently ignores any identifier not in this list. The string must match
the `taskIdentifier` passed to `BackgroundQueueDrainer` exactly.

**2. AppDelegate — register before launch completes:**

```swift
func application(_ app: UIApplication,
                 didFinishLaunchingWithOptions options: ...) -> Bool {
    drainer.register()   // must be called here, not later
    return true
}
```

iOS rejects registrations made after `application(_:didFinishLaunchingWithOptions:)`
returns. Calling `register()` at a later point has no effect.

**3. Scene/AppDelegate — schedule on every background entry:**

```swift
func sceneDidEnterBackground(_ scene: UIScene) {
    drainer.scheduleNextDrain()
}
```

Each call replaces any previously pending request. Calling it every time the
app backgrounds ensures there is always a request pending — if iOS runs the
task and the app backgrounds again before the user reopens it, the next drain
is already scheduled.

---

## Why `BGProcessingTask`, not `BGAppRefreshTask`?

| | `BGAppRefreshTask` | `BGProcessingTask` |
|---|---|---|
| Time budget | ~30 seconds | Several minutes |
| Network required | Optional | Configurable |
| Typical use | Content prefetch | Heavy processing |

Draining an offline queue of failed requests involves N sequential network calls.
With `BGAppRefreshTask`'s 30-second budget, a queue of more than a handful of
entries risks expiration mid-drain. `BGProcessingTask` provides a larger window
and can be configured to wait for connectivity (`requiresNetworkConnectivity =
true`), which is exactly the precondition the queue needs.

---

## Test approach

`BGTaskScheduler` cannot be controlled in unit tests (same constraint as
`NWPathMonitor`). The testability protocols decouple `BackgroundQueueDrainer`
from the system entirely:

- `MockBackgroundTaskScheduler` — captures `register` calls (identifier + handler)
  and `submit` calls (full `BGTaskRequest` for property inspection). `fireHandler`
  simulates iOS granting background time by calling the stored launch closure.
- `MockBackgroundTask` — records `setTaskCompletedCallCount` and
  `completionSuccess` (first call wins, matching BGTask's documented idempotent
  behaviour).

The entire test file is wrapped in `#if canImport(BackgroundTasks)` — these tests
compile and run on iOS/Mac Catalyst only.

Key behaviours verified:
- `register()` records the identifier and does not submit a request.
- `scheduleNextDrain()` submits a `BGProcessingTaskRequest` with the correct
  identifier, `requiresNetworkConnectivity = true`, and
  `requiresExternalPower = false`.
- `handleTask` installs the expiration handler synchronously (before any
  `await`) — verified with no yield between `fireHandler` and the assertion.
- Successful drain calls `setTaskCompleted(success: true)`.
- Expiration fires before the drain Task runs → `setTaskCompleted(success: false)`.
- After expiration + 200ms sleep, the cancelled drain Task has not called
  `setTaskCompleted` a second time.
