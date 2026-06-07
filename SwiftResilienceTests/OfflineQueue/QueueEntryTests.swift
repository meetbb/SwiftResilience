//
//  QueueEntryTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 07/06/26.
//

import XCTest
@testable import SwiftResilience

// MARK: - Test doubles

private struct SampleRequest: QueueableRequest {
    var url: URL
    var method: HTTPMethod
    var headers: [String: String]
    var body: Data?
    var timeout: TimeInterval
    var ttl: TimeInterval
    var priority: QueuePriority
    var idempotencyKey: String

    init(
        url: URL                   = URL(string: "https://api.example.com/posts")!,
        method: HTTPMethod         = .post,
        headers: [String: String]  = ["Content-Type": "application/json"],
        body: Data?                = Data("{\"title\":\"Hello\"}".utf8),
        timeout: TimeInterval      = 30,
        ttl: TimeInterval          = 86_400,
        priority: QueuePriority    = .normal,
        idempotencyKey: String     = "POST:https://api.example.com/posts:dGl0bGU="
    ) {
        self.url            = url
        self.method         = method
        self.headers        = headers
        self.body           = body
        self.timeout        = timeout
        self.ttl            = ttl
        self.priority       = priority
        self.idempotencyKey = idempotencyKey
    }
}

// MARK: - QueueEntry initialisation

final class QueueEntryInitTests: XCTestCase {

    func test_init_copiesURL() {
        let url = URL(string: "https://api.example.com/orders")!
        let entry = QueueEntry(SampleRequest(url: url))
        XCTAssertEqual(entry.url, url)
    }

    func test_init_copiesMethodAsRawString() {
        let entry = QueueEntry(SampleRequest(method: .put))
        XCTAssertEqual(entry.method, "PUT")
    }

    func test_init_copiesHeaders() {
        let headers = ["X-Custom": "value", "Content-Type": "application/json"]
        let entry = QueueEntry(SampleRequest(headers: headers))
        XCTAssertEqual(entry.headers, headers)
    }

    func test_init_copiesBody() {
        let body = Data("{\"key\":\"value\"}".utf8)
        let entry = QueueEntry(SampleRequest(body: body))
        XCTAssertEqual(entry.body, body)
    }

    func test_init_nilBody_storesNil() {
        let entry = QueueEntry(SampleRequest(body: nil))
        XCTAssertNil(entry.body)
    }

    func test_init_copiesToTimeout() {
        let entry = QueueEntry(SampleRequest(timeout: 60))
        XCTAssertEqual(entry.timeout, 60)
    }

    func test_init_copiesTTL() {
        let entry = QueueEntry(SampleRequest(ttl: 3_600))
        XCTAssertEqual(entry.ttl, 3_600)
    }

    func test_init_copiesPriorityAsRawInt() {
        let entry = QueueEntry(SampleRequest(priority: .critical))
        XCTAssertEqual(entry.priority, QueuePriority.critical.rawValue)
    }

    func test_init_copiesIdempotencyKey() {
        let key = "my-custom-key-abc"
        let entry = QueueEntry(SampleRequest(idempotencyKey: key))
        XCTAssertEqual(entry.idempotencyKey, key)
    }

    func test_init_usesProvidedID() {
        let id = UUID()
        let entry = QueueEntry(SampleRequest(), id: id)
        XCTAssertEqual(entry.id, id)
    }

    func test_init_generatesUniqueIDsByDefault() {
        let e1 = QueueEntry(SampleRequest())
        let e2 = QueueEntry(SampleRequest())
        XCTAssertNotEqual(e1.id, e2.id)
    }

    func test_init_usesProvidedEnqueuedAt() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = QueueEntry(SampleRequest(), enqueuedAt: date)
        XCTAssertEqual(entry.enqueuedAt, date)
    }

    func test_init_defaultEnqueuedAt_isApproximatelyNow() {
        let before = Date.now
        let entry = QueueEntry(SampleRequest())
        let after = Date.now
        XCTAssertGreaterThanOrEqual(entry.enqueuedAt, before)
        XCTAssertLessThanOrEqual(entry.enqueuedAt, after)
    }
}

// MARK: - QueueEntry.isExpired

final class QueueEntryExpiryTests: XCTestCase {

    func test_notExpired_whenEnqueuedNowWithDefaultTTL() {
        let entry = QueueEntry(SampleRequest(ttl: 86_400), enqueuedAt: .now)
        XCTAssertFalse(entry.isExpired)
    }

    func test_expired_whenEnqueuedBeyondTTL() {
        // enqueuedAt is 2 hours ago; TTL is 1 hour → expired
        let twoHoursAgo = Date.now.addingTimeInterval(-7_200)
        let entry = QueueEntry(SampleRequest(ttl: 3_600), enqueuedAt: twoHoursAgo)
        XCTAssertTrue(entry.isExpired)
    }

    func test_notExpired_whenJustUnderTTL() {
        // enqueuedAt is 60 seconds less than TTL ago — comfortably not expired.
        // Using a margin avoids the wall-clock race where Date.now advances
        // between the two Date.now calls inside isExpired.
        let justUnder = Date.now.addingTimeInterval(-(86_400 - 60))
        let entry = QueueEntry(SampleRequest(ttl: 86_400), enqueuedAt: justUnder)
        XCTAssertFalse(entry.isExpired)
    }

    func test_expired_whenJustOverTTL() {
        // enqueuedAt is 60 seconds more than TTL ago — comfortably expired.
        let justOver = Date.now.addingTimeInterval(-(86_400 + 60))
        let entry = QueueEntry(SampleRequest(ttl: 86_400), enqueuedAt: justOver)
        XCTAssertTrue(entry.isExpired)
    }

    func test_expired_whenTTLIsZero() {
        // TTL of zero means expire immediately — any elapsed time is too long
        let slightlyInThePast = Date.now.addingTimeInterval(-0.001)
        let entry = QueueEntry(SampleRequest(ttl: 0), enqueuedAt: slightlyInThePast)
        XCTAssertTrue(entry.isExpired)
    }
}

// MARK: - QueueEntry.asURLRequest

final class QueueEntryURLRequestTests: XCTestCase {

    func test_asURLRequest_setsURL() {
        let url = URL(string: "https://api.example.com/comments")!
        let entry = QueueEntry(SampleRequest(url: url))
        XCTAssertEqual(entry.asURLRequest().url, url)
    }

    func test_asURLRequest_setsHTTPMethod() {
        let entry = QueueEntry(SampleRequest(method: .patch))
        XCTAssertEqual(entry.asURLRequest().httpMethod, "PATCH")
    }

    func test_asURLRequest_setsBody() {
        let body = Data("{\"x\":1}".utf8)
        let entry = QueueEntry(SampleRequest(body: body))
        XCTAssertEqual(entry.asURLRequest().httpBody, body)
    }

    func test_asURLRequest_setsTimeout() {
        let entry = QueueEntry(SampleRequest(timeout: 45))
        XCTAssertEqual(entry.asURLRequest().timeoutInterval, 45)
    }

    func test_asURLRequest_forwardsOriginalHeaders() {
        let headers = ["Accept": "application/json"]
        let entry = QueueEntry(SampleRequest(headers: headers))
        XCTAssertEqual(entry.asURLRequest().value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func test_asURLRequest_injectsIdempotencyKeyHeader() {
        let key = "POST:https://api.example.com/posts:abc123"
        let entry = QueueEntry(SampleRequest(idempotencyKey: key))
        XCTAssertEqual(
            entry.asURLRequest().value(forHTTPHeaderField: "Idempotency-Key"),
            key
        )
    }
}

// MARK: - QueueEntry Codable round-trip

final class QueueEntryCodableTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func test_roundTrip_preservesAllFields() throws {
        let original = QueueEntry(
            SampleRequest(
                url: URL(string: "https://api.example.com/items")!,
                method: .delete,
                headers: ["Authorization": "Bearer token"],
                body: nil,
                timeout: 15,
                ttl: 7_200,
                priority: .high,
                idempotencyKey: "delete-key-xyz"
            ),
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
            enqueuedAt: Date(timeIntervalSince1970: 1_748_476_800)
        )

        let data    = try encoder.encode(original)
        let decoded = try decoder.decode(QueueEntry.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func test_roundTrip_withNilBody() throws {
        let original = QueueEntry(SampleRequest(body: nil))
        let decoded  = try decoder.decode(QueueEntry.self, from: try encoder.encode(original))
        XCTAssertNil(decoded.body)
    }

    func test_encodedJSON_containsHumanReadableMethod() throws {
        let entry = QueueEntry(SampleRequest(method: .post))
        let json  = try encoder.encode(entry)
        let text  = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"POST\""),
            "The encoded method should be the raw HTTP verb string, not an integer index.")
    }
}

// MARK: - QueueEntry Equatable

final class QueueEntryEquatableTests: XCTestCase {

    func test_equalEntries_areEqual() {
        let id   = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let e1   = QueueEntry(SampleRequest(), id: id, enqueuedAt: date)
        let e2   = QueueEntry(SampleRequest(), id: id, enqueuedAt: date)
        XCTAssertEqual(e1, e2)
    }

    func test_differentIDs_areNotEqual() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let e1 = QueueEntry(SampleRequest(), id: UUID(), enqueuedAt: date)
        let e2 = QueueEntry(SampleRequest(), id: UUID(), enqueuedAt: date)
        XCTAssertNotEqual(e1, e2)
    }
}
