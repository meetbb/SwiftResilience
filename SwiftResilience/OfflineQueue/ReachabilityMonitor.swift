//
//  ReachabilityMonitor.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 07/06/26.
//

import Network
import Foundation

// MARK: - ReachabilityMonitoring

/// Observes network path availability and publishes connectivity changes.
///
/// Defined as a protocol so `OfflineQueueEngine` can depend on an abstraction
/// rather than a concrete `NWPathMonitor`, keeping the engine fully testable
/// without real network calls.
///
/// ## Actor requirement
///
/// Conforming types must be actors. This ensures `isConnected` reads and
/// `connectivity` stream yields are serialised — no data races on the shared
/// connectivity state.
///
/// ## Usage
///
/// ```
/// let monitor = NetworkReachabilityMonitor()
/// monitor.start()
///
/// // Synchronous snapshot (safe inside another actor):
/// let online = await monitor.isConnected
///
/// // Event-driven drain loop:
/// for await connected in await monitor.connectivity {
///     if connected { await drainQueue() }
/// }
/// ```
public protocol ReachabilityMonitoring: Actor {
    
    /// The current connectivity state.
    ///
    /// `true` when the device has a usable network path (`NWPath.Status.satisfied`).
    /// `false` before the monitor is started or when the path is unsatisfied/requires connection.
    var isConnected: Bool { get }
    
    /// An infinite stream that emits `true` when a usable path becomes available
    /// and `false` when it is lost.
    ///
    /// The stream never completes under normal operation. The drain loop in
    /// `OfflineQueueEngine` iterates this stream for its entire lifetime.
    var connectivity: AsyncStream<Bool> { get }
}

// MARK: - NetworkReachabilityMonitor

/// A `ReachabilityMonitoring` implementation backed by `NWPathMonitor`.
///
/// ## Lifecycle
///
/// 1. Call `start()` once — typically inside `OfflineQueueEngine.init`.
/// 2. Optionally call `stop()` to cancel the monitor and finish the stream
///    (e.g., in tests or when tearing down the engine).
///
/// `NWPathMonitor` fires its handler immediately upon `start(queue:)` with the
/// current path, so `isConnected` reflects real state within one event-loop tick
/// after `start()` returns.
///
/// ## Threading
///
/// Path updates arrive on a private `DispatchQueue`. The handler dispatches
/// them back onto the actor via an unstructured `Task` so the actor's internal
/// state is always mutated on the actor's executor — never from the path queue.
public actor NetworkReachabilityMonitor: ReachabilityMonitoring {
    
    // MARK: - ReachabilityMonitoring
    
    /// The most recently observed connectivity state.
    /// Initialised to `false` (offline assumption) until the first path update arrives.
    public private(set) var isConnected: Bool = false
    
    /// Connectivity event stream. Backed by `_stream`; exposed via computed
    /// property so the actor boundary protects the underlying continuation.
    public var connectivity: AsyncStream<Bool> { _stream }
    
    // MARK: - Private state
    
    private let _stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    private let monitor: NWPathMonitor
    private let monitorQueue: DispatchQueue
    
    // MARK: - Initialisation
    
    /// Creates a monitor using a new `NWPathMonitor`.
    ///
    /// - Parameter monitor: Override for testing. Defaults to a fresh
    ///   `NWPathMonitor()` that observes all interface types.
    public init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        self.monitorQueue = DispatchQueue(
            label: "com.swiftresilience.reachability",
            qos: .utility
        )
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        self._stream = stream
        self.continuation = continuation
    }
    
    // MARK: - Lifecycle
    
    /// Starts the underlying `NWPathMonitor`.
    ///
    /// `NWPathMonitor` fires its `pathUpdateHandler` immediately with the
    /// current path on `start(queue:)`, so `isConnected` and the stream will
    /// reflect real state within one event-loop tick.
    ///
    /// Calling `start()` more than once on the same instance is a no-op from
    /// the framework's perspective (NWPathMonitor ignores redundant starts),
    /// but should be avoided in practice.
    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { [weak self] in
                await self?.handlePathUpdate(connected)
            }
        }
        monitor.start(queue: monitorQueue)
    }
    
    /// Stops the monitor and finishes the connectivity stream.
    ///
    /// After `stop()`, the `connectivity` stream completes and any `for await`
    /// loop iterating it will exit. Call this when tearing down the engine
    /// or in test teardown to prevent stream leaks.
    public func stop() {
        monitor.cancel()
        continuation.finish()
    }
    
    // MARK: - Private
    
    private func handlePathUpdate(_ connected: Bool) {
        isConnected = connected
        continuation.yield(connected)
    }
}
