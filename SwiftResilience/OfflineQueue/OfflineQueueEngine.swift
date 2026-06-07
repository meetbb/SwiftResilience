//
//  OfflineQueueEngine.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 07/06/26.
//

import Foundation

// MARK: - OfflineQueueError

/// Errors thrown directly by `OfflineQueueEngine`.
///
/// Note: errors from the underlying network call (4xx, `.noConnection`, etc.)
/// are not wrapped — they are rethrown as `NetworkError` so callers can
/// handle them with an exhaustive switch they already know.
public enum OfflineQueueError: Error, Sendable {

    /// The queue has reached `maxQueueSize`.
    ///
    /// The caller must decide whether to discard the new request, cancel an
    /// existing lower-priority entry, or surface an error to the user.
    case full
}

// MARK: - QueueEntryRequest (private adapter)

/// Bridges a persisted `QueueEntry` back into the `NetworkRequest` protocol
/// so it can be passed to `AsyncRequestEngine.send(_:)` during drain.
///
/// The `Idempotency-Key` header is included so every replay carries the same
/// token the server uses for deduplication.
private struct QueueEntryRequest: NetworkRequest {
    let url: URL
    let method: HTTPMethod
    let headers: [String: String]   // includes Idempotency-Key
    let body: Data?
    let timeout: TimeInterval

    /// Returns `nil` if `entry.method` is not a recognised `HTTPMethod` value.
    /// In practice this never happens — we always write the raw value from a
    /// valid `HTTPMethod` enum case. The failable init is a safety net for
    /// hypothetical schema drift.
    init?(_ entry: QueueEntry) {
        guard let method = HTTPMethod(rawValue: entry.method) else { return nil }
        self.url     = entry.url
        self.method  = method
        self.body    = entry.body
        self.timeout = entry.timeout

        var headers = entry.headers
        headers["Idempotency-Key"] = entry.idempotencyKey
        self.headers = headers
    }
}

// MARK: - OfflineQueueEngine

/// Composes `DiskQueueStore`, `ReachabilityMonitoring`, and `AsyncRequestEngine`
/// into a single offline-first delivery layer.
///
/// ## How it works
///
/// **Enqueue path** (`enqueue(_:)`)
/// 1. If the device is currently connected, attempt an immediate send through
///    `AsyncRequestEngine`. On success, nothing is written to disk.
/// 2. If the send fails with a connectivity error (`.noConnection`, `.timedOut`),
///    or if the device is already offline, the request is serialised to disk.
/// 3. All other errors (4xx, cancelled) are rethrown to the caller — they signal
///    a problem the server returned, not a connectivity gap.
///
/// **Drain loop** (started by `start()`)
/// 1. Subscribes to `reachabilityMonitor.connectivity`.
/// 2. On each `true` event, calls `runDrainCycle()`.
/// 3. The cycle sweeps expired entries, then sends each surviving entry through
///    `AsyncRequestEngine` in priority-FIFO order.
/// 4. Successfully sent entries are deleted. Entries that hit another
///    connectivity error pause the cycle — the queue waits for the next
///    reconnect event. Non-connectivity errors (4xx) delete the entry
///    without retrying — the server rejected it.
///
/// ## Lifecycle
///
/// ```swift
/// let monitor = NetworkReachabilityMonitor()
/// await monitor.start()                          // start NWPathMonitor
/// let engine  = try OfflineQueueEngine(reachabilityMonitor: monitor)
/// await engine.start()                           // begin drain loop
///
/// try await engine.enqueue(myRequest)            // fire-and-forget
/// ```
///
/// Call `stop()` to cancel the drain loop (e.g., on sign-out or in tests).
public actor OfflineQueueEngine {

    // MARK: - Configuration

    /// Maximum number of entries allowed on disk at one time.
    ///
    /// `enqueue` throws `OfflineQueueError.full` when this limit is reached.
    /// This is a soft limit — concurrent enqueues that both pass the count
    /// check before either writes may momentarily exceed it by one.
    public let maxQueueSize: Int

    // MARK: - Dependencies

    private let requestEngine: AsyncRequestEngine
    private let reachabilityMonitor: any ReachabilityMonitoring
    let store: DiskQueueStore   // `internal` so tests can inspect state directly

    // MARK: - State

    private var drainTask: Task<Void, Never>?

    // MARK: - Initialisation

    /// Full injection init — used directly in tests and advanced configurations.
    ///
    /// - Parameters:
    ///   - requestEngine: The engine that sends requests over the network.
    ///   - reachabilityMonitor: A pre-started monitor that publishes connectivity events.
    ///   - store: The disk-backed queue store.
    ///   - maxQueueSize: Maximum queued entries. Defaults to 500.
    public init(
        requestEngine: AsyncRequestEngine = AsyncRequestEngine(),
        reachabilityMonitor: any ReachabilityMonitoring,
        store: DiskQueueStore,
        maxQueueSize: Int = 500
    ) {
        self.requestEngine       = requestEngine
        self.reachabilityMonitor = reachabilityMonitor
        self.store               = store
        self.maxQueueSize        = maxQueueSize
    }

    // MARK: - Lifecycle

    /// Starts the drain loop.
    ///
    /// Call once after the reachability monitor has been started.
    /// Calling `start()` again while the drain loop is running replaces the
    /// existing loop task — avoid this in production.
    public func start() {
        drainTask?.cancel()
        drainTask = Task { await self.drainLoop() }
    }

    /// Cancels the drain loop.
    ///
    /// In-progress sends are not interrupted — the loop stops at the next
    /// opportunity to check for cancellation.
    public func stop() {
        drainTask?.cancel()
        drainTask = nil
    }

    // MARK: - Public API

    /// Delivers a request, using the network immediately when online and
    /// falling back to disk when offline.
    ///
    /// - Throws:
    ///   - `OfflineQueueError.full` if the queue has reached `maxQueueSize`.
    ///   - `NetworkError` for non-connectivity failures (e.g. 4xx responses)
    ///     when the device is online and the immediate send fails.
    public func enqueue(_ request: some QueueableRequest) async throws {
        // --- Fast path: attempt immediate send when connected ---
        if await reachabilityMonitor.isConnected {
            do {
                try await requestEngine.send(request)
                return  // delivered — nothing written to disk
            } catch NetworkError.noConnection, NetworkError.timedOut {
                // Connectivity lost between the check and the send.
                // Fall through to queue the request on disk.
            } catch {
                // Server error or cancellation — rethrow, do not queue.
                throw error
            }
        }

        // --- Queue path ---
        let currentCount = await store.count()
        guard currentCount < maxQueueSize else {
            throw OfflineQueueError.full
        }

        let entry = QueueEntry(request)
        try await store.save(entry)
    }

    /// Removes a queued entry by ID without sending it.
    ///
    /// A no-op if the entry has already been sent or expired.
    public func cancel(id: UUID) async {
        await store.delete(id: id)
    }

    // MARK: - Drain

    /// Runs one full drain cycle: sweeps expired entries, then sends each
    /// surviving entry in priority-FIFO order.
    ///
    /// Marked `internal` (not `private`) so test code can invoke a drain
    /// directly without needing to drive the reachability stream.
    func runDrainCycle() async {
        await store.deleteExpired()
        let entries = await store.load()

        for entry in entries {
            guard !Task.isCancelled else { break }

            // Reconstruct a NetworkRequest from the stored fields.
            guard let request = QueueEntryRequest(entry) else {
                // Entry has an unrecognised HTTP method — corrupted entry.
                // Delete it and move on rather than blocking the queue.
                await store.delete(id: entry.id)
                continue
            }

            do {
                try await requestEngine.send(request)
                await store.delete(id: entry.id)   // successfully delivered

            } catch NetworkError.noConnection, NetworkError.timedOut {
                // Network is down again — abort this cycle.
                // The entry stays on disk and will be retried on the next
                // reconnect event.
                break

            } catch {
                // Server rejected the request (4xx, cancelled, etc.).
                // Retrying won't help — remove the entry.
                await store.delete(id: entry.id)
            }
        }
    }

    // MARK: - Private

    private func drainLoop() async {
        for await connected in await reachabilityMonitor.connectivity {
            guard connected, !Task.isCancelled else { continue }
            await runDrainCycle()
        }
    }
}
