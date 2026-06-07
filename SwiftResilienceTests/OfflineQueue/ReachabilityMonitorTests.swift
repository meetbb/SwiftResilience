//
//  ReachabilityMonitorTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 07/06/26.
//

import XCTest
@testable import SwiftResilience

// MARK: - MockReachabilityMonitor
//
// A fully-controllable fake that satisfies the `ReachabilityMonitoring` protocol.
// Used here to test the mock itself, and reused by `OfflineQueueEngineTests`
// in Section 5 to control the connectivity state without touching real network.
//
// `internal` so it is visible across the test target without needing a separate file.

actor MockReachabilityMonitor: ReachabilityMonitoring {

    // MARK: ReachabilityMonitoring

    private(set) var isConnected: Bool
    var connectivity: AsyncStream<Bool> { _stream }

    // MARK: Private

    private let _stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    // MARK: Init

    /// - Parameter isConnected: Starting connectivity state. Defaults to `false`
    ///   (offline) to match the real monitor's initial assumption.
    init(isConnected: Bool = false) {
        self.isConnected = isConnected
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        self._stream = stream
        self.continuation = cont
    }

    // MARK: Test controls

    /// Simulates a network path change — updates `isConnected` and emits
    /// the new value into the `connectivity` stream.
    func setConnected(_ connected: Bool) {
        isConnected = connected
        continuation.yield(connected)
    }

    /// Finishes the stream, causing any iterating `for await` loop to exit.
    /// Call this in test teardown to prevent stream leaks.
    func finish() {
        continuation.finish()
    }
}

// MARK: - MockReachabilityMonitor protocol conformance

final class MockReachabilityMonitorConformanceTests: XCTestCase {

    func test_conformsToReachabilityMonitoring() {
        // Compile-time check: MockReachabilityMonitor must satisfy the protocol.
        // If this assignment compiles, the conformance is correct.
        let _: any ReachabilityMonitoring = MockReachabilityMonitor()
    }
}

// MARK: - MockReachabilityMonitor initial state

final class MockReachabilityMonitorInitialStateTests: XCTestCase {

    func test_defaultIsConnected_isFalse() async {
        let monitor = MockReachabilityMonitor()
        let connected = await monitor.isConnected
        XCTAssertFalse(connected)
    }

    func test_customInitialState_isReflected() async {
        let monitor = MockReachabilityMonitor(isConnected: true)
        let connected = await monitor.isConnected
        XCTAssertTrue(connected)
    }
}

// MARK: - MockReachabilityMonitor setConnected

final class MockReachabilityMonitorSetConnectedTests: XCTestCase {

    func test_setConnected_updatesIsConnected() async {
        let monitor = MockReachabilityMonitor(isConnected: false)
        await monitor.setConnected(true)
        let connected = await monitor.isConnected
        XCTAssertTrue(connected)
    }

    func test_setConnected_false_updatesIsConnected() async {
        let monitor = MockReachabilityMonitor(isConnected: true)
        await monitor.setConnected(false)
        let connected = await monitor.isConnected
        XCTAssertFalse(connected)
    }
}

// MARK: - MockReachabilityMonitor stream delivery

final class MockReachabilityMonitorStreamTests: XCTestCase {

    func test_setConnected_emitsValueIntoStream() async {
        let monitor = MockReachabilityMonitor()

        // Collect the first emitted value from the stream.
        let received = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                // Wait for one value then return it.
                for await value in await monitor.connectivity {
                    return value
                }
                return nil
            }
            group.addTask {
                // Small yield so the stream consumer task starts first.
                await Task.yield()
                await monitor.setConnected(true)
                await monitor.finish()
                return nil
            }
            var result: Bool? = nil
            for await value in group {
                if let v = value { result = v }
            }
            return result
        }

        XCTAssertEqual(received, true)
    }

    func test_multipleUpdates_areDeliveredInOrder() async {
        let monitor = MockReachabilityMonitor()
        var received: [Bool] = []

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var count = 0
                for await value in await monitor.connectivity {
                    received.append(value)
                    count += 1
                    if count == 3 { break }
                }
            }
            group.addTask {
                await Task.yield()
                await monitor.setConnected(true)
                await monitor.setConnected(false)
                await monitor.setConnected(true)
            }
        }

        XCTAssertEqual(received, [true, false, true])
    }

    func test_finish_terminatesStream() async {
        let monitor = MockReachabilityMonitor()

        var iterationCount = 0
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in await monitor.connectivity {
                    iterationCount += 1
                }
            }
            group.addTask {
                await Task.yield()
                await monitor.finish()
            }
        }

        // The loop should have exited with zero emissions since we
        // finished without yielding any values.
        XCTAssertEqual(iterationCount, 0)
    }
}

// MARK: - NetworkReachabilityMonitor compile-time conformance

final class NetworkReachabilityMonitorConformanceTests: XCTestCase {

    func test_conformsToReachabilityMonitoring() {
        // Compile-time check only.
        // Behavioural testing of NetworkReachabilityMonitor requires a real
        // device or simulator and is covered by integration / manual tests —
        // NWPathMonitor's path cannot be controlled programmatically in XCTest.
        let _: any ReachabilityMonitoring = NetworkReachabilityMonitor()
    }
}
