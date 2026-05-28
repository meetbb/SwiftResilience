//
//  ExponentialRetryPolicyTests.swift
//  SwiftResilienceTests
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import XCTest
@testable import SwiftResilience

final class ExponentialRetryPolicyTests: XCTestCase {
    
    func testDelayCalculation() {
        let policy = ExponentialRetryPolicy(maxRetries: 3, baseDelay: 1)
        
        XCTAssertEqual(policy.delay(forAttempt: 0), 1)
        XCTAssertEqual(policy.delay(forAttempt: 1), 2)
        XCTAssertEqual(policy.delay(forAttempt: 2), 4)
        XCTAssertNil(policy.delay(forAttempt: 3))
    }
}
