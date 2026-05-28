//
//  ExponentialRetryPolicy.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import Foundation

public struct ExponentialRetryPolicy: RetryPolicy {
    
    private let maxRetries: Int
    private let baseDelay: TimeInterval
    
    public init(maxRetries: Int = 3, baseDelay: TimeInterval = 1.0) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
    }
    
    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        
        guard attempt < maxRetries else {
            return nil
        }
        
        return baseDelay * pow(2.0, Double(attempt))
    }
}
