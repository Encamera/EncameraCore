//
//  ProgressReportingChunkStore.swift
//  EncameraCoreTests
//
//  A chunk store that reports a fixed series of transfer fractions before it
//  serves each chunk, the way CloudKit's `perRecordProgressBlock` does.
//

import Foundation
@testable import EncameraCore

final class ProgressReportingChunkStore: ChunkedBlobStoring, @unchecked Sendable {

    private let backing: InMemoryChunkedBlobStore
    let fractions: [Double]

    init(backing: InMemoryChunkedBlobStore, fractions: [Double] = [0.25, 0.5, 1]) {
        self.backing = backing
        self.fractions = fractions
    }

    func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
        try await backing.fetchChunk(mediaRecordName: mediaRecordName, index: index)
    }

    func fetchChunk(mediaRecordName: String,
                    index: Int,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        fractions.forEach(progress)
        return try await backing.fetchChunk(mediaRecordName: mediaRecordName, index: index)
    }

    func fetchChunkStaged(mediaRecordName: String,
                          index: Int,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> FetchedChunk {
        FetchedChunk(data: try await fetchChunk(mediaRecordName: mediaRecordName, index: index, progress: progress),
                     stagedFileURL: nil)
    }

    @discardableResult
    func uploadChunks(enc3FileURL: URL,
                      mediaRecordName: String,
                      existingChunks: ExistingChunkPolicy,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
        try await backing.uploadChunks(enc3FileURL: enc3FileURL, mediaRecordName: mediaRecordName,
                                       existingChunks: existingChunks, progress: progress)
    }

    func delete(mediaRecordName: String, chunkCount: Int) async throws {
        try await backing.delete(mediaRecordName: mediaRecordName, chunkCount: chunkCount)
    }
}

/// Collects the fractions a progress closure receives, from any thread.
final class FractionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var fractions: [Double] { lock.withLock { recorded } }

    func record(_ fraction: Double) {
        lock.withLock { recorded.append(fraction) }
    }
}
