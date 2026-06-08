//
//  AsyncRequestEngine.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import Foundation

// The main engine. Fires requests, handles retries, and deduplicates
// concurrent calls to the same endpoint.
//
// Declared as an actor so the inFlightTasks dictionary is never touched
// from two places at once — no locks needed.
public actor AsyncRequestEngine {

    private let session: any NetworkSession
    private let retryPolicy: (any RetryPolicy)?
    private let eventSink: (any RequestEventSink)?

    // Tracks requests that are currently in flight.
    // Key: a hashable snapshot of the request's identifying properties.
    // Value: the Task doing the actual work.
    private var inFlightTasks: [RequestIdentity: Task<(Data, HTTPURLResponse), Error>] = [:]

    /// Creates an engine.
    ///
    /// - Parameters:
    ///   - session: The underlying transport. Defaults to `URLSession.shared`.
    ///   - retryPolicy: Controls whether and how long to wait between retries.
    ///     Pass `nil` (the default) to disable automatic retries.
    ///   - eventSink: An optional observer that receives structured lifecycle
    ///     events for every request (started, succeeded, failed, etc.). Useful
    ///     for logging, analytics, and metrics collection. Defaults to `nil`.
    public init(
        session: any NetworkSession = URLSession.shared,
        retryPolicy: (any RetryPolicy)? = nil,
        eventSink: (any RequestEventSink)? = nil
    ) {
        self.session    = session
        self.retryPolicy = retryPolicy
        self.eventSink  = eventSink
    }

    // MARK: - Public

    @discardableResult
    public func send(_ request: some NetworkRequest) async throws -> (Data, HTTPURLResponse) {
        let identity = RequestIdentity(request)
        let traceID  = UUID()

        // If an identical request is already running, wait for its result
        // instead of firing a second one. Both callers get the same response.
        if let existing = inFlightTasks[identity] {
            // Emit .deduplicated before awaiting — the event correctly describes
            // what is happening to THIS caller (it is not making a network call).
            // The actor may suspend here, but inFlightTasks is already stable.
            await eventSink?.record(
                .deduplicated(traceID: traceID, url: request.url, method: request.method)
            )
            return try await existing.value
        }

        // No existing task — register one synchronously (no await before this
        // point) so a concurrent send() with the same identity finds it and
        // deduplicates rather than firing a second request.
        let startDate = Date()
        let task = Task { try await self.executeWithRetry(request, traceID: traceID, startDate: startDate) }
        inFlightTasks[identity] = task

        // Clean up once the task finishes, regardless of success or failure.
        defer { inFlightTasks.removeValue(forKey: identity) }

        return try await task.value
    }

    // MARK: - Private

    // The actual request + retry loop. Separated from send() so that
    // deduplication logic above stays easy to read.
    //
    // traceID and startDate are passed in from send() so that all events
    // for this logical request share the same identifier and duration anchor.
    //
    // .started is emitted here rather than in send() to guarantee ordering:
    // this function runs on the actor's executor as a Task, so .started is
    // always enqueued at the sink before any subsequent events (retryScheduled,
    // succeeded, failed) that this same function emits later.
    private func executeWithRetry(
        _ request: some NetworkRequest,
        traceID: UUID,
        startDate: Date
    ) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = request.asURLRequest()
        var attempt = 0

        // Emit .started before the first network call.
        await eventSink?.record(
            .started(traceID: traceID, url: request.url, method: request.method)
        )

        while true {
            do {
                let (data, response) = try await session.data(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.underlying(URLError(.badServerResponse))
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    await eventSink?.record(
                        .succeeded(
                            traceID: traceID,
                            statusCode: httpResponse.statusCode,
                            duration: Date().timeIntervalSince(startDate),
                            attempt: attempt
                        )
                    )
                    return (data, httpResponse)
                }

                // Non-2xx — check if it's worth retrying.
                let error = NetworkError.httpError(statusCode: httpResponse.statusCode, data: data)
                try await retryOrThrow(error, attempt: &attempt, traceID: traceID)

            } catch let error as NetworkError {
                throw error
            } catch {
                // URLSession throws URLError for connection/timeout issues.
                // Map to our type so callers always deal with NetworkError.
                let mapped = (error as? URLError)?.asNetworkError ?? NetworkError.underlying(error)
                try await retryOrThrow(mapped, attempt: &attempt, traceID: traceID)
            }
        }
    }

    // Checks whether the error is retryable and whether the policy allows
    // another attempt. Sleeps for the prescribed delay, then increments attempt.
    // Throws if we should give up — emitting .failed before throwing so the
    // sink always receives a terminal event for every .started.
    private func retryOrThrow(
        _ error: NetworkError,
        attempt: inout Int,
        traceID: UUID
    ) async throws {
        guard error.isRetryable, let delay = retryPolicy?.delay(forAttempt: attempt) else {
            // Non-retryable error or retry budget exhausted — terminal failure.
            await eventSink?.record(.failed(traceID: traceID, error: error, attempt: attempt))
            throw error
        }

        // Emit .retryScheduled before sleeping so the sink knows a retry is
        // coming and how long the delay will be.
        await eventSink?.record(
            .retryScheduled(traceID: traceID, attempt: attempt, delay: delay)
        )

        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch {
            // Task was cancelled mid-sleep — treat as a terminal failure.
            await eventSink?.record(.failed(traceID: traceID, error: .cancelled, attempt: attempt))
            throw NetworkError.cancelled
        }

        attempt += 1
    }
}
