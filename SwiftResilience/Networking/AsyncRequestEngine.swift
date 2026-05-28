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

    // Tracks requests that are currently in flight.
    // Key: a hashable snapshot of the request's identifying properties.
    // Value: the Task doing the actual work.
    private var inFlightTasks: [RequestIdentity: Task<(Data, HTTPURLResponse), Error>] = [:]

    public init(
        session: any NetworkSession = URLSession.shared,
        retryPolicy: (any RetryPolicy)? = nil
    ) {
        self.session = session
        self.retryPolicy = retryPolicy
    }

    // MARK: - Public

    @discardableResult
    public func send(_ request: some NetworkRequest) async throws -> (Data, HTTPURLResponse) {
        let identity = RequestIdentity(request)

        // If an identical request is already running, wait for its result
        // instead of firing a second one. Both callers get the same response.
        if let existing = inFlightTasks[identity] {
            return try await existing.value
        }

        // No existing task — kick one off and register it.
        let task = Task { try await self.executeWithRetry(request) }
        inFlightTasks[identity] = task

        // Clean up once the task finishes, regardless of success or failure.
        defer { inFlightTasks.removeValue(forKey: identity) }

        return try await task.value
    }

    // MARK: - Private

    // The actual request + retry loop. Separated from send() so that
    // deduplication logic above stays easy to read.
    private func executeWithRetry(_ request: some NetworkRequest) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = request.asURLRequest()
        var attempt = 0

        while true {
            do {
                let (data, response) = try await session.data(for: urlRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.underlying(URLError(.badServerResponse))
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    return (data, httpResponse)
                }

                // Non-2xx — check if it's worth retrying
                let error = NetworkError.httpError(statusCode: httpResponse.statusCode, data: data)
                try await retryOrThrow(error, attempt: &attempt)

            } catch let error as NetworkError {
                throw error
            } catch {
                // URLSession throws URLError for connection/timeout issues.
                // Map to our type so callers always deal with NetworkError.
                let mapped = (error as? URLError)?.asNetworkError ?? NetworkError.underlying(error)
                try await retryOrThrow(mapped, attempt: &attempt)
            }
        }
    }

    // Checks whether the error is retryable and whether the policy allows
    // another attempt. Sleeps for the prescribed delay, then increments attempt.
    // Throws if we should give up.
    private func retryOrThrow(_ error: NetworkError, attempt: inout Int) async throws {
        guard error.isRetryable, let delay = retryPolicy?.delay(forAttempt: attempt) else {
            throw error
        }

        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch {
            // Task was cancelled mid-sleep — stop retrying.
            throw NetworkError.cancelled
        }

        attempt += 1
    }
}
