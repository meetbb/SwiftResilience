//
//  NetworkSession.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import Foundation

/// A protocol that abstracts the single method `AsyncRequestEngine` needs
/// from `URLSession`.
///
/// **Why not inject `URLSession` directly?**
///
/// `URLSession` is a concrete class. If the engine depended on it directly,
/// tests would have to either:
///   (a) spin up a real HTTP server, or
///   (b) use `URLProtocol` subclassing — which is powerful but verbose.
///
/// By depending on this protocol instead, tests inject a lightweight
/// `MockNetworkSession` that returns canned responses in microseconds,
/// with no network I/O at all.
///
/// `URLSession` gains conformance via the extension below — zero
/// production code changes required.
public protocol NetworkSession: Sendable {

    /// Performs an async data task and returns the raw bytes + metadata.
    /// Mirrors the signature of `URLSession.data(for:)` exactly.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

// MARK: - URLSession conformance

/// `URLSession` already implements this method natively (iOS 15+, macOS 12+).
/// The conformance declaration is all that's needed.
extension URLSession: NetworkSession {}
