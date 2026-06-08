//
//  BackgroundQueueProtocols.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 08/06/26.
//

#if canImport(BackgroundTasks)
import BackgroundTasks
import Foundation

// MARK: - BackgroundTaskHandling

/// Abstracts a single `BGTask` execution unit so `BackgroundQueueDrainer`
/// can be tested without a live iOS background task scheduler.
///
/// `BGTask` already exposes both members declared here, so conformance is
/// satisfied by an empty retroactive extension — no bridging required.
///
/// ## Members
///
/// - `expirationHandler` — assigned by `BackgroundQueueDrainer` before the
///   drain starts. The system calls it on an arbitrary thread when it needs
///   to reclaim resources early. The handler should cancel any in-progress
///   work and call `setTaskCompleted(success: false)`.
///
/// - `setTaskCompleted(success:)` — must be called exactly once per task.
///   iOS terminates the app extension if it is not called before the
///   expiration handler fires, so every code path must reach it.
public protocol BackgroundTaskHandling: AnyObject {

    /// Called by iOS when it needs to reclaim background resources before
    /// the task completes normally. Set this before beginning any work.
    var expirationHandler: (() -> Void)? { get set }

    /// Reports the outcome of the background task to iOS.
    ///
    /// - Parameter success: `true` if the task completed its intended work;
    ///   `false` if it was interrupted by expiration or encountered an error.
    func setTaskCompleted(success: Bool)
}

/// `BGTask` already exposes `expirationHandler` and `setTaskCompleted(success:)`.
/// This extension adds the protocol conformance label — no implementation needed.
extension BGTask: BackgroundTaskHandling {}

// MARK: - BackgroundTaskScheduling

/// Abstracts `BGTaskScheduler` so `BackgroundQueueDrainer` can be unit-tested
/// with a controllable stand-in rather than the live system scheduler.
///
/// ## Why not extend `BGTaskScheduler` directly?
///
/// `BGTaskScheduler` already has a `register(forTaskWithIdentifier:using:launchHandler:)`
/// method whose `launchHandler` takes `(BGTask) -> Void`. If we added a second
/// overload whose handler takes `(any BackgroundTaskHandling) -> Void`, the
/// compiler would face an ambiguous call site in the conformance extension.
///
/// Using a `SystemBackgroundTaskScheduler` wrapper class sidesteps this entirely:
/// the wrapper forwards both calls to `BGTaskScheduler.shared` with concrete
/// `BGTask` types, and the protocol uses `BackgroundTaskHandling` throughout.
///
/// ## Conformance in production
///
/// Use `SystemBackgroundTaskScheduler.shared` — the provided wrapper that
/// delegates to `BGTaskScheduler.shared`.
///
/// ## Conformance in tests
///
/// Inject a `MockBackgroundTaskScheduler` (defined in the test target) to
/// capture registrations and submitted requests without touching the system.
public protocol BackgroundTaskScheduling: AnyObject {

    /// Registers a launch handler for a background task identifier.
    ///
    /// Must be called before `application(_:didFinishLaunchingWithOptions:)`
    /// returns — iOS rejects registrations made after launch completes.
    ///
    /// - Parameters:
    ///   - identifier: The task identifier declared in the app's Info.plist
    ///     under `BGTaskSchedulerPermittedIdentifiers`.
    ///   - queue: The dispatch queue on which to call `launchHandler`.
    ///     Pass `nil` to use a system-managed serial queue.
    ///   - launchHandler: Called by iOS when background time is granted.
    ///     Receives the task to execute and complete.
    func register(
        forTaskWithIdentifier identifier: String,
        using queue: DispatchQueue?,
        launchHandler: @escaping (any BackgroundTaskHandling) -> Void
    )

    /// Submits a task request, scheduling it for future background execution.
    ///
    /// - Parameter taskRequest: A `BGProcessingTaskRequest` or
    ///   `BGAppRefreshTaskRequest` describing when the task should run.
    /// - Throws: `BGTaskScheduler.Error` if the identifier is not registered
    ///   or if the app has reached the system request limit.
    func submit(_ taskRequest: BGTaskRequest) throws
}

// MARK: - SystemBackgroundTaskScheduler

/// The production `BackgroundTaskScheduling` implementation.
///
/// Wraps `BGTaskScheduler.shared` and bridges the `(BGTask) -> Void` launch
/// handler signature to the `(any BackgroundTaskHandling) -> Void` signature
/// used by the protocol and `BackgroundQueueDrainer`.
///
/// ## Usage
///
/// ```
/// let drainer = BackgroundQueueDrainer(
///     taskIdentifier: "com.myapp.queue-drain",
///     engine: offlineQueueEngine
///     // scheduler defaults to SystemBackgroundTaskScheduler.shared
/// )
/// ```
public final class SystemBackgroundTaskScheduler: BackgroundTaskScheduling {

    /// The shared singleton. Use this in all production code.
    public static let shared = SystemBackgroundTaskScheduler()

    private init() {}

    public func register(
        forTaskWithIdentifier identifier: String,
        using queue: DispatchQueue?,
        launchHandler: @escaping (any BackgroundTaskHandling) -> Void
    ) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: queue
        ) { task in
            // `task` is a `BGTask` (subclass `BGProcessingTask` or
            // `BGAppRefreshTask`). Both conform to `BackgroundTaskHandling`
            // via the extension above, so this bridging closure is zero-cost.
            launchHandler(task)
        }
    }

    public func submit(_ taskRequest: BGTaskRequest) throws {
        try BGTaskScheduler.shared.submit(taskRequest)
    }
}

#endif  // canImport(BackgroundTasks)
