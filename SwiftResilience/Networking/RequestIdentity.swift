//
//  RequestIdentity.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 28/05/26.
//

import Foundation

// A hashable snapshot of a request's identifying properties.
// Used as the key in AsyncRequestEngine's in-flight task dictionary.
//
// Timeout is intentionally excluded — two requests to the same endpoint
// with different timeouts are still the "same" request for deduplication.
struct RequestIdentity: Hashable {
    let url: URL
    let method: HTTPMethod
    let headers: [String: String]
    let body: Data?

    init(_ request: some NetworkRequest) {
        url     = request.url
        method  = request.method
        headers = request.headers
        body    = request.body
    }
}
