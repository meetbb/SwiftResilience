//
//  DiskQueueStore.swift
//  SwiftResilience
//
//  Created by Meet Brahmbhatt on 07/06/26.
//

import Foundation

// MARK: - DiskQueueStoreError

/// Errors produced by `DiskQueueStore` operations.
public enum DiskQueueStoreError: Error, Sendable {
    /// The store's root directory could not be located or created.
    case directoryUnavailable(any Error)
    /// A `QueueEntry` could not be encoded to JSON before writing.
    case encodingFailed(UUID, any Error)
    /// A file on disk could not be decoded back into a `QueueEntry`.
    case decodingFailed(URL, any Error)
}

// MARK: - DiskQueueStore

/// The persistence layer for the offline request queue.
///
/// Each `QueueEntry` is stored as a separate JSON file named `<entry.id>.json`
/// inside a dedicated subdirectory of the app's Application Support container.
/// One file per entry means:
///
/// - **Atomic writes** — writing one entry never touches another.
/// - **Atomic deletes** — removing one entry is a single `FileManager` call.
/// - **No locking** — the actor boundary serialises all access, so two
///   concurrent saves never corrupt each other.
///
/// `DiskQueueStore` is pure persistence — no retry logic, no network calls,
/// no reachability awareness. `OfflineQueueEngine` owns all of that.
///
/// ## Testability
///
/// Pass a custom `directory` URL in tests to write into a temporary folder
/// that is cleaned up after the test runs, keeping tests hermetic.
public actor DiskQueueStore {
    
    // MARK: Properties
    
    /// The directory where entry files are written.
    /// Exposed as `public` so tests can inspect the filesystem directly.
    public let directory: URL
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    // MARK: Initialisation
    
    /// Creates a store that writes to `directory`.
    ///
    /// - Parameter directory: The folder that will hold entry files.
    ///   The directory is created on first use if it does not already exist.
    ///   Defaults to `Application Support/SwiftResilience/OfflineQueue/`.
    public init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            self.directory = try DiskQueueStore.defaultDirectory()
        }
        try FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }
    
    // MARK: - Public API
    
    /// Persists a `QueueEntry` to disk.
    ///
    /// The entry is written to `<directory>/<entry.id>.json`.
    /// Calling `save` for an entry whose file already exists overwrites it,
    /// which is intentional — a retry after a partial write gets a clean slate.
    ///
    /// - Throws: `DiskQueueStoreError.encodingFailed` if JSON serialisation fails.
    public func save(_ entry: QueueEntry) throws {
        let data = try encode(entry)
        let fileURL = fileURL(for: entry.id)
        try data.write(to: fileURL, options: .atomic)
    }
    
    /// Loads all non-expired entries from disk, sorted for drain ordering.
    ///
    /// Files that cannot be decoded are skipped and logged to `stderr` rather
    /// than throwing — a single corrupt file should not block the entire queue.
    ///
    /// **Sort order:** priority descending (critical first), then `enqueuedAt`
    /// ascending (oldest first within the same priority). This preserves causal
    /// ordering: a "create post" enqueued before an "edit post" at the same
    /// priority will always be sent first.
    ///
    /// - Returns: All valid, non-expired entries in drain order.
    public func load() -> [QueueEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> QueueEntry? in
                guard let data = try? Data(contentsOf: url),
                      let entry = try? decoder.decode(QueueEntry.self, from: data)
                else {
                    fputs("SwiftResilience: failed to decode queue entry at \(url.lastPathComponent)\n", stderr)
                    return nil
                }
                return entry
            }
            .filter { !$0.isExpired }
            .sorted {
                if $0.priority != $1.priority {
                    return $0.priority > $1.priority   // higher priority first
                }
                return $0.enqueuedAt < $1.enqueuedAt   // older entry first (FIFO)
            }
    }
    
    /// Removes the file for a single entry.
    ///
    /// A no-op if the file does not exist — safe to call after a successful
    /// send even if the entry was already evicted by `deleteExpired`.
    public func delete(id: UUID) {
        let url = fileURL(for: id)
        try? FileManager.default.removeItem(at: url)
    }
    
    /// Scans all files in the directory and deletes those whose TTL has elapsed.
    ///
    /// Called at the start of every drain cycle before `load()`.
    /// Separating deletion from loading keeps `load()` predictable — it never
    /// returns an entry that `deleteExpired` would have removed.
    ///
    /// - Returns: The number of entries deleted.
    @discardableResult
    public func deleteExpired() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        
        var count = 0
        for url in files where url.pathExtension == "json" {
            guard let data  = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(QueueEntry.self, from: data)
            else { continue }
            
            if entry.isExpired {
                try? FileManager.default.removeItem(at: url)
                count += 1
            }
        }
        return count
    }
    
    /// Returns the number of entries currently on disk (expired or not).
    ///
    /// Used by `OfflineQueueEngine` to enforce `maxQueueSize` before writing
    /// a new entry.
    public func count() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }
    
    // MARK: - Private helpers
    
    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
    
    private func encode(_ entry: QueueEntry) throws -> Data {
        do {
            return try encoder.encode(entry)
        } catch {
            throw DiskQueueStoreError.encodingFailed(entry.id, error)
        }
    }
    
    // MARK: - Default directory
    
    private static func defaultDirectory() throws -> URL {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return appSupport
                .appendingPathComponent("SwiftResilience", isDirectory: true)
                .appendingPathComponent("OfflineQueue",    isDirectory: true)
        } catch {
            throw DiskQueueStoreError.directoryUnavailable(error)
        }
    }
}
