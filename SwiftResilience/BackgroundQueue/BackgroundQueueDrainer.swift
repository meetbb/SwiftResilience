//
//  BackgroundQueueDrainer.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 08/06/26.
//

#if canImport(BackgroundTasks)
import BackgroundTasks
import Foundation

// MARK: - BackgroundQueueDrainer

/// Connects `OfflineQueueEngine` to iOS's `BGTaskScheduler` so pending requests
/// are drained while the app is suspended in the background.
///
/// ## Why it exists
///
/// `OfflineQueueEngine` drains requests whenever the device reconnects to the
/// network while the app is in the foreground. But if the device comes online
/// while the app is suspended, the drain loop is not running and queued requests
/// sit on disk until the next foreground session.
///
/// `BackgroundQueueDrainer` fixes this gap by scheduling a `BGProcessingTask`.
/// When iOS grants background time — typically while the device is idle, plugged
/// in, and connected to Wi-Fi — the drainer runs a full drain cycle and reports
/// completion back to the system.
///
/// ## Setup (two calls, both required)
///
/// **1. In `AppDelegate.application(_:didFinishLaunchingWithOptions:)`:**
///
/// ```swift
/// drainer.register()
/// ```
///
/// iOS requires all task identifiers to be registered before the app finishes
/// launching. Registering later silently has no effect.
///
/// **2. In `SceneDelegate.sceneDidEnterBackground(_:)` or
///    `AppDelegate.applicationDidEnterBackground(_:)`:**
///
/// ```swift
/// drainer.scheduleNextDrain()
/// ```
///
/// This submits a `BGProcessingTaskRequest` so iOS knows to grant background
/// time in a future opportunity. Without this call, the registered handler is
/// never triggered.
///
/// ## Info.plist
///
/// Add your task identifier to `BGTaskSchedulerPermittedIdentifiers`:
///
/// ```xml
/// <key>BGTaskSchedulerPermittedIdentifiers</key>
/// <array>
///     <string>com.myapp.queue-drain</string>
/// </array>
/// ```
///
/// ## Full example
///
/// ```
/// // AppDelegate
/// let monitor  = NetworkReachabilityMonitor()
/// let engine   = try OfflineQueueEngine(reachabilityMonitor: monitor)
/// let drainer  = BackgroundQueueDrainer(
///     taskIdentifier: "com.myapp.queue-drain",
///     engine: engine
/// )
///
/// func application(_ app: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
///     drainer.register()
///     Task { await monitor.start(); await engine.start() }
///     return true
/// }
///
/// func applicationDidEnterBackground(_ application: UIApplication) {
///     drainer.scheduleNextDrain()
/// }
/// ```
public final class BackgroundQueueDrainer {

    // MARK: - Properties

    /// The identifier registered in Info.plist under
    /// `BGTaskSchedulerPermittedIdentifiers`. Must match exactly.
    public let taskIdentifier: String

    private let engine: OfflineQueueEngine
    private let scheduler: any BackgroundTaskScheduling

    // MARK: - Initialisation

    /// Creates a drainer.
    ///
    /// - Parameters:
    ///   - taskIdentifier: The background task identifier. Must be declared in
    ///     the app's Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
    ///   - engine: The offline queue engine whose `runDrainCycle()` will be
    ///     called when iOS grants background time.
    ///   - scheduler: The background task scheduler. Defaults to
    ///     `SystemBackgroundTaskScheduler.shared` (backed by
    ///     `BGTaskScheduler.shared`). Inject a mock in tests.
    public init(
        taskIdentifier: String,
        engine: OfflineQueueEngine,
        scheduler: any BackgroundTaskScheduling = SystemBackgroundTaskScheduler.shared
    ) {
        self.taskIdentifier = taskIdentifier
        self.engine         = engine
        self.scheduler      = scheduler
    }

    // MARK: - Public API

    /// Registers the drain handler with the background task scheduler.
    ///
    /// Call once, before `application(_:didFinishLaunchingWithOptions:)` returns.
    /// iOS silently ignores registrations made after the app finishes launching.
    ///
    /// Calling `register()` a second time for the same identifier replaces the
    /// previously registered handler — avoid this in production.
    public func register() {
        scheduler.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleTask(task)
        }
    }

    /// Submits a `BGProcessingTaskRequest` so iOS will grant background time
    /// at the next suitable opportunity.
    ///
    /// Call from `sceneDidEnterBackground` or `applicationDidEnterBackground`
    /// each time the app moves to the background. If a request for this
    /// identifier is already pending, the new request replaces it.
    ///
    /// The request is configured with `requiresNetworkConnectivity = true` —
    /// draining without a network connection would only produce failures, so
    /// iOS will wait for connectivity before granting time.
    ///
    /// Submission errors (e.g., the identifier is not registered, or the
    /// system pending-request limit is reached) are silently discarded —
    /// the queue will drain on the next foreground session instead.
    public func scheduleNextDrain() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower       = false
        try? scheduler.submit(request)
    }

    // MARK: - Private

    /// Executes a full drain cycle for the given background task.
    ///
    /// Sets the expiration handler before launching any async work so there is
    /// no window where iOS could fire expiration before the handler is in place.
    /// The drain runs as an unstructured `Task` so it outlives this synchronous
    /// function call and can be cancelled cleanly by the expiration handler.
    private func handleTask(_ task: any BackgroundTaskHandling) {
        // Capture the drain task in a local so the expiration handler can cancel it.
        var drainTask: Task<Void, Never>?

        // Install the expiration handler first — before any await — so there is
        // no gap where iOS could call expiration with no handler registered.
        task.expirationHandler = {
            // iOS is reclaiming resources. Cancel any in-progress work so the
            // drain loop exits at its next cooperative cancellation checkpoint.
            drainTask?.cancel()
            // Report that we did not complete successfully. iOS uses this to
            // decide whether to reschedule the task sooner.
            task.setTaskCompleted(success: false)
        }

        drainTask = Task { [engine] in
            await engine.runDrainCycle()

            // Only report success if the task was not cancelled by expiration.
            // setTaskCompleted is idempotent — if expiration fired first and
            // already called it with `false`, this call is a no-op.
            guard !Task.isCancelled else { return }
            task.setTaskCompleted(success: true)
        }
    }
}

#endif  // canImport(BackgroundTasks)
