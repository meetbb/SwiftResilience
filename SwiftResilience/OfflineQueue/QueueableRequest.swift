//
//  QueueableRequest.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 07/06/26.
//

import Foundation

// MARK: - QueuePriority

/// The processing priority of a queued request.
///
/// During a drain cycle entries are sent highest-priority first.
/// Within the same priority, older entries are sent before newer ones (FIFO).
///
/// Conforms to `Comparable` so sorted collections work without custom comparators.
public enum QueuePriority: Int, Comparable, Sendable {
    
    /// Routine background work — analytics pings, non-urgent syncs.
    case normal = 0
    
    /// User-initiated mutations — posting a comment, submitting a form.
    case high = 1
    
    /// Actions whose failure is immediately visible — purchases, auth tokens.
    case critical = 2
    
    public static func < (lhs: QueuePriority, rhs: QueuePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - QueueableRequest

/// A `NetworkRequest` that can survive offline periods by being persisted to disk
/// and replayed automatically when connectivity is restored.
///
/// ## Conforming to `QueueableRequest`
///
/// All three properties have sensible defaults via the protocol extension,
/// so a minimal conformance requires no extra code beyond what `NetworkRequest` already needs:
///
/// ```swift
/// struct PostCommentRequest: QueueableRequest {
///     let url: URL
///     let method: HTTPMethod = .post
///     let body: Data?
///     // ttl, priority, and idempotencyKey come from the extension
/// }
/// ```
///
/// Override any property when the default is not appropriate:
///
/// ```swift
/// struct StartLiveStreamRequest: QueueableRequest {
///     let url: URL
///     let method: HTTPMethod = .post
///     // 5-minute TTL — stale after the event window closes
///     var ttl: TimeInterval { 300 }
///     var priority: QueuePriority { .critical }
/// }
/// ```
///
/// ## Idempotency
///
/// The default `idempotencyKey` is a stable fingerprint of the request's
/// URL, method, and body. The engine attaches it as an `Idempotency-Key`
/// header automatically so the server can safely ignore replayed duplicates.
/// If your endpoint uses its own idempotency scheme, override this property
/// to return that key instead.
public protocol QueueableRequest: NetworkRequest {
    
    /// How long this entry is allowed to wait in the queue before being discarded.
    ///
    /// Measured in seconds from the moment the entry is first persisted.
    /// Expired entries are deleted silently during each drain cycle.
    /// Defaults to 24 hours.
    var ttl: TimeInterval { get }
    
    /// The order in which this entry is processed relative to other queued entries.
    ///
    /// Higher priority entries are sent first. Within the same priority,
    /// FIFO order is preserved. Defaults to `.normal`.
    var priority: QueuePriority { get }
    
    /// A stable string that uniquely identifies this logical request.
    ///
    /// Attached as the `Idempotency-Key` HTTP header on replay so the server
    /// can deduplicate requests it may have already processed before the app
    /// went offline.
    ///
    /// The default implementation derives a deterministic fingerprint from
    /// the request's URL, HTTP method, and body. Override this when your API
    /// uses its own idempotency token scheme.
    var idempotencyKey: String { get }
}

// MARK: - Default implementations

public extension QueueableRequest {
    
    /// 24 hours — safe default for most durable user-initiated mutations.
    var ttl: TimeInterval { 86_400 }
    
    /// `.normal` — appropriate for the majority of background requests.
    var priority: QueuePriority { .normal }
    
    /// A deterministic fingerprint built from URL + method + body.
    ///
    /// Stable across app launches for the same logical request, which is
    /// a requirement for server-side idempotency checking.
    ///
    /// - The URL and method are used as-is (both are always present).
    /// - The body is Base64-encoded if present; an empty string is used for
    ///   bodyless requests (GET, DELETE) so they still produce a valid key.
    var idempotencyKey: String {
        let bodyFragment = body?.base64EncodedString() ?? ""
        return "\(method.rawValue):\(url.absoluteString):\(bodyFragment)"
    }
}
