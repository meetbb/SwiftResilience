//
//  BackgroundQueueDrainerTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 08/06/26.
//
//  NOTE: BackgroundTasks is an iOS-only framework. These tests compile and run
//  on iOS/iPadOS/Mac Catalyst only. On macOS the entire file is skipped by the
//  #if canImport guard — the same approach used for NWPathMonitor tests.

#if canImport(BackgroundTasks)
import XCTest
import BackgroundTasks
@testable import SwiftResilience

// MARK: - Test infrastructure

/// Captures `register` and `submit` calls so tests can assert on them without
/// touching the real `BGTaskScheduler.shared`.
///
/// `fireHandler` is the test entry point that simulates iOS granting background
/// time and calling the registered launch handler.
final class MockBackgroundTaskScheduler: BackgroundTaskScheduling {

    private(set) var registeredIdentifiers: [String] = []
    private var registeredHandlers: [String: (any BackgroundTaskHandling) -> Void] = [:]
    private(set) var submittedRequests: [BGTaskRequest] = []

    func register(
        forTaskWithIdentifier identifier: String,
        using queue: DispatchQueue?,
        launchHandler: @escaping (any BackgroundTaskHandling) -> Void
    ) {
        registeredIdentifiers.append(identifier)
        registeredHandlers[identifier] = launchHandler
    }

    func submit(_ taskRequest: BGTaskRequest) throws {
        submittedRequests.append(taskRequest)
    }

    /// Simulates iOS calling the registered launch handler for `identifier`.
    /// The caller provides the mock task that will be passed to the handler.
    func fireHandler(_ task: any BackgroundTaskHandling, forIdentifier identifier: String) {
        registeredHandlers[identifier]?(task)
    }
}

/// Controllable stand-in for `BGTask`.
///
/// Records how many times `setTaskCompleted` was called and what `success`
/// value was passed on the first call (matching the idempotent behaviour
/// documented in the BGTask API — only the first call counts).
final class MockBackgroundTask: BackgroundTaskHandling {
    var expirationHandler: (() -> Void)?
    private(set) var setTaskCompletedCallCount = 0
    private(set) var completionSuccess: Bool?

    func setTaskCompleted(success: Bool) {
        setTaskCompletedCallCount += 1
        if completionSuccess == nil {
            // Only the first call's value is recorded — mirroring BGTask's
            // documented idempotent behaviour.
            completionSuccess = success
        }
    }
}

// MARK: - Helpers

/// Creates an `OfflineQueueEngine` backed by a fresh temp directory.
/// Returns both the engine and the directory URL so the caller can register
/// an `addTeardownBlock` for cleanup.
private func makeEngine() throws -> (OfflineQueueEngine, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("BGDrainer-\(UUID().uuidString)", isDirectory: true)
    let store = try DiskQueueStore(directory: dir)
    let monitor = MockReachabilityMonitor(isConnected: false)
    let engine  = OfflineQueueEngine(
        requestEngine: AsyncRequestEngine(),
        reachabilityMonitor: monitor,
        store: store
    )
    return (engine, dir)
}

private let testIdentifier = "com.swiftresilience.test.queue-drain"

// MARK: - Registration tests

final class BackgroundQueueDrainerRegistrationTests: XCTestCase {

    func test_register_recordsIdentifierInScheduler() throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )

        drainer.register()

        XCTAssertEqual(scheduler.registeredIdentifiers, [testIdentifier])
    }

    func test_register_doesNotSubmitATaskRequest() throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )

        drainer.register()

        XCTAssertTrue(
            scheduler.submittedRequests.isEmpty,
            "register() must not submit a BGTaskRequest — that is scheduleNextDrain's responsibility."
        )
    }

    func test_taskIdentifier_matchesInitParameter() throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let drainer = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: MockBackgroundTaskScheduler()
        )

        XCTAssertEqual(drainer.taskIdentifier, testIdentifier)
    }
}

// MARK: - Scheduling tests

final class BackgroundQueueDrainerSchedulingTests: XCTestCase {

    func test_scheduleNextDrain_submitsRequestWithCorrectIdentifier() throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )

        drainer.scheduleNextDrain()

        XCTAssertEqual(scheduler.submittedRequests.count, 1)
        XCTAssertEqual(scheduler.submittedRequests.first?.identifier, testIdentifier)
    }

    func test_scheduleNextDrain_submitsProcessingTaskRequest() throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )

        drainer.scheduleNextDrain()

        XCTAssertTrue(
            scheduler.submittedRequests.first is BGProcessingTaskRequest,
            "Queue draining needs extended background time — must use BGProcessingTaskRequest, not BGAppRefreshTaskRequest."
        )
    }

    func test_scheduleNextDrain_requiresNetworkConnectivity() throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )

        drainer.scheduleNextDrain()

        let request = scheduler.submittedRequests.first as? BGProcessingTaskRequest
        XCTAssertEqual(
            request?.requiresNetworkConnectivity, true,
            "Draining without connectivity produces only failures — requiresNetworkConnectivity must be true."
        )
    }

    func test_scheduleNextDrain_doesNotRequireExternalPower() throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )

        drainer.scheduleNextDrain()

        let request = scheduler.submittedRequests.first as? BGProcessingTaskRequest
        XCTAssertEqual(
            request?.requiresExternalPower, false,
            "Queue draining should run on battery-powered devices — requiresExternalPower must be false."
        )
    }

    func test_scheduleNextDrain_calledMultipleTimes_eachSubmitsRequest() throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )

        drainer.scheduleNextDrain()
        drainer.scheduleNextDrain()

        // The mock captures both submissions. In production, BGTaskScheduler
        // replaces the previous pending request — both calls are still correct
        // because each background entry should schedule the next drain.
        XCTAssertEqual(scheduler.submittedRequests.count, 2)
    }
}

// MARK: - Task handling tests

final class BackgroundQueueDrainerTaskHandlingTests: XCTestCase {

    /// The expiration handler must be assigned before any async work begins so
    /// there is no window where iOS fires expiration with no handler in place.
    func test_handleTask_installsExpirationHandlerSynchronously() throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )
        drainer.register()

        let mockTask = MockBackgroundTask()
        XCTAssertNil(mockTask.expirationHandler, "No handler should exist before the task fires.")

        scheduler.fireHandler(mockTask, forIdentifier: testIdentifier)

        XCTAssertNotNil(
            mockTask.expirationHandler,
            "expirationHandler must be installed synchronously inside handleTask, before any await."
        )
    }

    /// When the drain cycle completes normally, `setTaskCompleted(success: true)` is called.
    func test_handleTask_drainCompletes_callsSetTaskCompletedWithTrue() async throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )
        drainer.register()

        let mockTask = MockBackgroundTask()
        scheduler.fireHandler(mockTask, forIdentifier: testIdentifier)

        // An empty queue drains in microseconds; 200ms gives ample headroom for
        // the cooperative scheduler to run the drain Task to completion.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            mockTask.completionSuccess, true,
            "setTaskCompleted(success: true) must be called after a successful drain cycle."
        )
    }

    /// When the expiration handler fires, `setTaskCompleted(success: false)` is called.
    func test_handleTask_expirationFires_callsSetTaskCompletedWithFalse() throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )
        drainer.register()

        let mockTask = MockBackgroundTask()
        scheduler.fireHandler(mockTask, forIdentifier: testIdentifier)

        // Fire expiration synchronously, before the drain Task runs.
        // The drain Task has been created but the cooperative scheduler has not
        // yet had a chance to execute it — so expiration wins the first-call race.
        mockTask.expirationHandler?()

        XCTAssertEqual(
            mockTask.completionSuccess, false,
            "setTaskCompleted(success: false) must be called when expiration fires."
        )
    }

    /// After the expiration handler fires and cancels the drain task, the cancelled
    /// drain task must not call `setTaskCompleted` a second time.
    func test_handleTask_expirationFires_cancelledDrainDoesNotCallSetTaskCompletedAgain() async throws {
        let (engine, dir) = try makeEngine()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let scheduler = MockBackgroundTaskScheduler()
        let drainer   = BackgroundQueueDrainer(
            taskIdentifier: testIdentifier,
            engine: engine,
            scheduler: scheduler
        )
        drainer.register()

        let mockTask = MockBackgroundTask()
        scheduler.fireHandler(mockTask, forIdentifier: testIdentifier)
        mockTask.expirationHandler?()   // first call → false

        // Wait for the cancelled drain Task to run and hit its cancellation
        // check — confirming it exits early without a second setTaskCompleted.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            mockTask.setTaskCompletedCallCount, 1,
            "The cancelled drain task must not call setTaskCompleted a second time after expiration."
        )
        XCTAssertEqual(mockTask.completionSuccess, false)
    }
}

#endif  // canImport(BackgroundTasks)
