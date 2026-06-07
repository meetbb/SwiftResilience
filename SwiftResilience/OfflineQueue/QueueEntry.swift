//
//  QueueEntry.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 07/06/26.
//

import Foundation

// MARK: - QueueEntry

/// A serialisable snapshot of a `QueueableRequest` plus the metadata
/// the queue needs to manage, order, and expire it.
///
/// ## Role in the pipeline
///
/// `QueueEntry` is the unit of storage — one entry, one file on disk.
/// It is *pure data*: no network calls, no file I/O, no async work.
/// The `DiskQueueStore` reads and writes it; `OfflineQueueEngine` consults
/// it for ordering and TTL decisions.
///
/// ## Why copy fields instead of storing the request directly
///
/// `NetworkRequest` is a protocol. Protocols cannot be made `Codable`
/// directly because the compiler cannot know at serialisation time which
/// concrete type to decode into. Copying the individual fields into a
/// plain struct sidesteps the existential problem and gives us a stable,
/// version-safe disk format that doesn't change when the request type does.
///
/// ## Relationship to `QueueableRequest`
///
/// `QueueEntry` is initialised from any `QueueableRequest` via
/// `QueueEntry.init(_:)`. The engine never touches the original request
/// type after that point — everything flows through the entry.
public struct QueueEntry: Codable, Sendable {

    // MARK: Identity

    /// Stable unique identifier for this entry.
    ///
    /// Used as the filename on disk (`<id>.json`) and as the handle
    /// for explicit cancellation via `OfflineQueueEngine.cancel(id:)`.
    public let id: UUID

    // MARK: Request fields

    /// The fully-resolved endpoint URL.
    public let url: URL

    /// The HTTP verb — stored as the raw `String` value ("GET", "POST", …)
    /// so the on-disk JSON is human-readable without needing to know the
    /// `HTTPMethod` enum.
    public let method: String

    /// HTTP headers for this request.
    /// Does not include the `Idempotency-Key` header — the engine injects
    /// that at send time from `idempotencyKey` so the header stays current
    /// on replay.
    public let headers: [String: String]

    /// The raw encoded body, if any.
    /// `nil` for GET and DELETE requests.
    public let body: Data?

    /// Per-request timeout forwarded to `URLRequest.timeoutInterval`.
    public let timeout: TimeInterval

    // MARK: Queue metadata

    /// The instant this entry was first written to disk.
    ///
    /// Used together with `ttl` to determine whether the entry has expired:
    /// `Date.now.timeIntervalSince(enqueuedAt) > ttl` → expired.
    public let enqueuedAt: Date

    /// Maximum age of this entry in seconds, measured from `enqueuedAt`.
    ///
    /// Entries that exceed their TTL are deleted silently during a drain
    /// cycle without being sent to the server.
    public let ttl: TimeInterval

    /// Drain ordering weight. Higher values are processed first.
    /// Within the same priority, entries are ordered by `enqueuedAt` ascending.
    public let priority: Int

    /// Stable idempotency token attached as `Idempotency-Key` on replay.
    public let idempotencyKey: String

    // MARK: - Computed helpers

    /// Whether this entry has lived in the queue longer than its declared TTL.
    ///
    /// Evaluated at the moment of the call — call this inside a drain cycle,
    /// not at creation time.
    public var isExpired: Bool {
        Date.now.timeIntervalSince(enqueuedAt) > ttl
    }

    /// Reconstructs a `URLRequest` from the stored fields.
    ///
    /// Called by `OfflineQueueEngine` at drain time to hand off to
    /// `AsyncRequestEngine`. The `Idempotency-Key` header is injected here
    /// so every replay carries the same stable token the server uses to
    /// deduplicate.
    public func asURLRequest() -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody   = body
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        return request
    }
}

// MARK: - Initialisation from QueueableRequest

public extension QueueEntry {

    /// Creates a `QueueEntry` from any `QueueableRequest`.
    ///
    /// - Parameters:
    ///   - request: The request to snapshot.
    ///   - id: Override the entry ID. Defaults to a new UUID. Pass a fixed
    ///     value in tests to make assertions deterministic.
    ///   - enqueuedAt: Override the enqueue timestamp. Defaults to `Date.now`.
    ///     Pass a fixed value in tests that exercise TTL logic.
    init(
        _ request: some QueueableRequest,
        id: UUID = UUID(),
        enqueuedAt: Date = .now
    ) {
        self.id             = id
        self.url            = request.url
        self.method         = request.method.rawValue
        self.headers        = request.headers
        self.body           = request.body
        self.timeout        = request.timeout
        self.enqueuedAt     = enqueuedAt
        self.ttl            = request.ttl
        self.priority       = request.priority.rawValue
        self.idempotencyKey = request.idempotencyKey
    }
}

// MARK: - Equatable

// Synthesised `Codable` is automatic. `Equatable` is derived manually
// so `Data?` (body) participates in equality checks correctly.
extension QueueEntry: Equatable {

    public static func == (lhs: QueueEntry, rhs: QueueEntry) -> Bool {
        lhs.id             == rhs.id
        && lhs.url         == rhs.url
        && lhs.method      == rhs.method
        && lhs.headers     == rhs.headers
        && lhs.body        == rhs.body
        && lhs.timeout     == rhs.timeout
        && lhs.enqueuedAt  == rhs.enqueuedAt
        && lhs.ttl         == rhs.ttl
        && lhs.priority    == rhs.priority
        && lhs.idempotencyKey == rhs.idempotencyKey
    }
}
