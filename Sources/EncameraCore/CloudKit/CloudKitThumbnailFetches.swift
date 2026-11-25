//
//  CloudKitThumbnailFetches.swift
//  EncameraCore
//
//  One thumbnail fetch per record at a time, for the whole process. Every album
//  grid cell and gallery has its own `CloudKitFileAccess`, so without this a
//  missing preview is fetched once per caller. A record that has no thumbnail
//  is remembered for a while, so callers fail at once instead of asking again.
//

import Foundation

actor CloudKitThumbnailFetches {

    static let shared = CloudKitThumbnailFetches()

    /// How long a record that answered `notFound` is not asked again.
    static let missingThumbnailMemory: TimeInterval = 5 * 60

    private var fetchesInFlight: [String: Task<Void, Error>] = [:]
    private var missingSince: [String: Date] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Runs `fetch` for `recordName` unless one is already running, in which case
    /// the caller waits for that one and gets its outcome. The fetch runs in its
    /// own task, so a caller that is cancelled does not cancel it for the others.
    ///
    /// - Throws: `CloudKitMediaStoreError.notFound` without calling `fetch` when
    ///   the record answered `notFound` within `missingThumbnailMemory`; otherwise
    ///   whatever `fetch` throws.
    func fetchThumbnail(recordName: String,
                        using fetch: @escaping @Sendable () async throws -> Void) async throws {
        if let since = missingSince[recordName] {
            if now().timeIntervalSince(since) < Self.missingThumbnailMemory {
                throw CloudKitMediaStoreError.notFound
            }
            missingSince[recordName] = nil
        }
        if let running = fetchesInFlight[recordName] {
            return try await running.value
        }
        let task = Task { try await fetch() }
        fetchesInFlight[recordName] = task
        do {
            try await task.value
            fetchesInFlight[recordName] = nil
        } catch {
            fetchesInFlight[recordName] = nil
            if case .notFound = error as? CloudKitMediaStoreError {
                missingSince[recordName] = now()
            }
            throw error
        }
    }

    /// Forgets that `recordName` had no thumbnail, as when one is attached to it.
    func forgetMissingThumbnail(recordName: String) {
        missingSince[recordName] = nil
    }

    /// Forgets every missing thumbnail. Tests call this between cases.
    func removeAll() {
        missingSince = [:]
    }
}
