//
//  HTTPMethod.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import Foundation

/// Represents the HTTP verb for a network request.
///
/// Defined as an enum (not a String typedef) so the compiler
/// catches typos at build time and exhaustive switch statements
/// are possible in routing or logging code.
///
/// `Sendable` conformance is automatic for enums with no
/// associated values, but we state it explicitly so that
/// `NetworkRequest` — which carries an `HTTPMethod` — can
/// also be `Sendable`.
public enum HTTPMethod: String, Sendable {
    case get    = "GET"
    case post   = "POST"
    case put    = "PUT"
    case patch  = "PATCH"
    case delete = "DELETE"
}
