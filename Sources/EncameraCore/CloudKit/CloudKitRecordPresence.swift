//
//  CloudKitRecordPresence.swift
//  EncameraCore
//
//  The check that must pass before a source copy whose bytes are in CloudKit is
//  deleted: the record is on the server, in the expected album, with the expected
//  size. Every such delete asks this one function.
//

import Foundation

/// What the server holds under one record name, measured against the album and
/// size a source copy expects.
enum CloudKitRecordPresence: Equatable, Sendable, DebugPrintable {
    /// In the expected album, with the expected size.
    case present
    /// No record under this name.
    case absent
    /// A record in the expected album whose size is not the expected size.
    case sizeMismatch(recordSizeBytes: Int64)
    /// A record under this name that another album owns. It is not a copy of
    /// the source, whatever its size.
    case inAnotherAlbum(owner: String)

    /// Whether `recordName` exists in CloudKit in `albumID` with `sizeBytes`. Uses
    /// the strongly consistent fetch-by-record-ID (`fetchRecordMetadata`), not the
    /// eventually consistent `fetchMetadata` query, so a record saved moments
    /// earlier is seen rather than reported missing. Throws what the fetch throws.
    static func check(recordName: String,
                      albumID: String,
                      sizeBytes: Int64,
                      store: CloudKitMediaStoring) async throws -> CloudKitRecordPresence {
        guard let metadata = try await store.fetchRecordMetadata(recordName: recordName) else {
            printDebug("verify MISS recordName=\(recordName) — no record in CloudKit")
            return .absent
        }
        guard metadata.albumID == albumID else {
            printDebug("verify OTHER ALBUM recordName=\(recordName) expected=\(albumID) owner=\(metadata.albumID)")
            return .inAnotherAlbum(owner: metadata.albumID)
        }
        guard metadata.sizeBytes == sizeBytes else {
            printDebug("verify SIZE MISMATCH recordName=\(recordName) local=\(sizeBytes) remote=\(metadata.sizeBytes)")
            return .sizeMismatch(recordSizeBytes: metadata.sizeBytes)
        }
        printDebug("verify ok recordName=\(recordName) sizeBytes=\(sizeBytes)")
        return .present
    }
}
