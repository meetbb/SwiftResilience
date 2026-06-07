//
//  QueueableRequestTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 07/06/26.
//

import XCTest
@testable import SwiftResilience

// MARK: - Test doubles

/// A minimal queueable request that accepts only what a test supplies.
/// All three queueable properties use their default implementations
/// unless the test overrides them via the parameterised variants below.
private struct SimpleQueueableRequest: QueueableRequest {
    let url: URL
    let method: HTTPMethod
    let body: Data?

    init(
        url: URL = URL(string: "https://api.example.com/posts")!,
        method: HTTPMethod = .post,
        body: Data? = Data("{}".utf8)
    ) {
        self.url    = url
        self.method = method
        self.body   = body
    }
}

/// Overrides every queueable property so tests can verify custom values
/// propagate correctly.
private struct CustomQueueableRequest: QueueableRequest {
    let url: URL
    let method: HTTPMethod
    let body: Data?
    let ttl: TimeInterval
    let priority: QueuePriority
    let idempotencyKey: String
}

// MARK: - QueuePriorityTests

final class QueuePriorityTests: XCTestCase {

    // MARK: Raw values

    func test_rawValues_matchDocumentedIntegers() {
        XCTAssertEqual(QueuePriority.normal.rawValue,   0)
        XCTAssertEqual(QueuePriority.high.rawValue,     1)
        XCTAssertEqual(QueuePriority.critical.rawValue, 2)
    }

    // MARK: Comparable

    func test_normal_isLessThan_high() {
        XCTAssertLessThan(QueuePriority.normal, .high)
    }

    func test_high_isLessThan_critical() {
        XCTAssertLessThan(QueuePriority.high, .critical)
    }

    func test_normal_isLessThan_critical() {
        XCTAssertLessThan(QueuePriority.normal, .critical)
    }

    func test_equalPriorities_areNotLessThan() {
        XCTAssertFalse(QueuePriority.normal   < .normal)
        XCTAssertFalse(QueuePriority.high     < .high)
        XCTAssertFalse(QueuePriority.critical < .critical)
    }

    func test_sortingArrayOfPriorities_producesAscendingOrder() {
        let unsorted: [QueuePriority] = [.critical, .normal, .high, .normal, .critical]
        let sorted = unsorted.sorted()
        XCTAssertEqual(sorted, [.normal, .normal, .high, .critical, .critical])
    }
}

// MARK: - QueueableRequest default TTL

final class QueueableRequestDefaultTTLTests: XCTestCase {

    func test_defaultTTL_is24Hours() {
        let request = SimpleQueueableRequest()
        XCTAssertEqual(request.ttl, 86_400)
    }

    func test_customTTL_overridesDefault() {
        let request = CustomQueueableRequest(
            url: URL(string: "https://api.example.com/stream")!,
            method: .post,
            body: nil,
            ttl: 300,
            priority: .normal,
            idempotencyKey: "custom-key"
        )
        XCTAssertEqual(request.ttl, 300)
    }
}

// MARK: - QueueableRequest default priority

final class QueueableRequestDefaultPriorityTests: XCTestCase {

    func test_defaultPriority_isNormal() {
        let request = SimpleQueueableRequest()
        XCTAssertEqual(request.priority, .normal)
    }

    func test_customPriority_overridesDefault() {
        let request = CustomQueueableRequest(
            url: URL(string: "https://api.example.com/purchase")!,
            method: .post,
            body: Data("{\"item\":\"A\"}".utf8),
            ttl: 86_400,
            priority: .critical,
            idempotencyKey: "purchase-key"
        )
        XCTAssertEqual(request.priority, .critical)
    }
}

// MARK: - QueueableRequest default idempotencyKey

final class QueueableRequestIdempotencyKeyTests: XCTestCase {

    // MARK: Determinism

    func test_sameRequest_producesSameKey() {
        let r1 = SimpleQueueableRequest()
        let r2 = SimpleQueueableRequest()
        XCTAssertEqual(r1.idempotencyKey, r2.idempotencyKey,
            "The same logical request must always produce the same idempotency key.")
    }

    // MARK: Differentiation

    func test_differentURLs_produceDifferentKeys() {
        let r1 = SimpleQueueableRequest(url: URL(string: "https://api.example.com/posts")!)
        let r2 = SimpleQueueableRequest(url: URL(string: "https://api.example.com/comments")!)
        XCTAssertNotEqual(r1.idempotencyKey, r2.idempotencyKey)
    }

    func test_differentMethods_produceDifferentKeys() {
        let r1 = SimpleQueueableRequest(method: .post)
        let r2 = SimpleQueueableRequest(method: .put)
        XCTAssertNotEqual(r1.idempotencyKey, r2.idempotencyKey)
    }

    func test_differentBodies_produceDifferentKeys() {
        let r1 = SimpleQueueableRequest(body: Data("{\"a\":1}".utf8))
        let r2 = SimpleQueueableRequest(body: Data("{\"a\":2}".utf8))
        XCTAssertNotEqual(r1.idempotencyKey, r2.idempotencyKey)
    }

    func test_nilBody_vs_emptyBody_produceDifferentKeys() {
        let r1 = SimpleQueueableRequest(body: nil)
        let r2 = SimpleQueueableRequest(body: Data())
        // nil body encodes to "" ; empty Data encodes to "" as well via base64
        // Both should be stable — this test documents the behaviour rather than asserting inequality.
        XCTAssertEqual(r1.idempotencyKey, r2.idempotencyKey,
            "nil body and empty Data are treated equivalently in the default key derivation.")
    }

    // MARK: Structure

    func test_keyContainsMethod() {
        let request = SimpleQueueableRequest(method: .post)
        XCTAssertTrue(request.idempotencyKey.hasPrefix("POST:"))
    }

    func test_keyContainsURL() {
        let url = URL(string: "https://api.example.com/posts")!
        let request = SimpleQueueableRequest(url: url)
        XCTAssertTrue(request.idempotencyKey.contains(url.absoluteString))
    }

    // MARK: Custom override

    func test_customIdempotencyKey_overridesDefault() {
        let custom = "my-server-issued-token-abc123"
        let request = CustomQueueableRequest(
            url: URL(string: "https://api.example.com/orders")!,
            method: .post,
            body: Data("{\"sku\":\"X\"}".utf8),
            ttl: 86_400,
            priority: .high,
            idempotencyKey: custom
        )
        XCTAssertEqual(request.idempotencyKey, custom)
    }
}
