//
//  RetryPolicy.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import Foundation

public protocol RetryPolicy {
    func delay(forAttempt attempt: Int) -> TimeInterval?
}
