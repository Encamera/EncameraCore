//
//  CloudKitStoreTestHooks.swift
//  EncameraCore
//
//  UI-test-only fault-injection points for the CloudKit store. All hooks default
//  to inert values; the app sets them from launch arguments inside
//  `UITestMode.setupIfNeeded()`, so production builds are unaffected.
//

import Foundation

/// Test-only configuration `CloudKitMediaStore` consults so a UI test can make a
/// delete or an album save fail the way a device with no connectivity does.
public enum CloudKitStoreTestHooks {

    /// When true, `delete(recordName:)` and `deleteAlbum(albumID:)` throw
    /// `CloudKitMediaStoreError.retry` — the same classification a transient
    /// connectivity failure maps to — without contacting the server. Everything
    /// else — uploads, fetches, the change feed — still works, which is what makes
    /// this a connectivity simulation for the delete path rather than an offline
    /// app: the queued intent has to survive on its own merits.
    public static var failDeletes: Bool = false

    /// When true, `saveAlbum(_:)` throws `CloudKitMediaStoreError.retry` without
    /// contacting the server, so a rename, hide or cover change stays `dirty` in
    /// the album's `album.json` until a launch without the hook lets the
    /// reconciler push it. Media uploads and fetches are untouched.
    public static var failAlbumSaves: Bool = false

    /// Awaited by `CloudKitChunkedBlobStore.uploadChunks` before each chunk it
    /// writes, with the number of this blob's chunks already on the server. While
    /// it is set, every chunk is saved in its own batch, so the count is exact and a
    /// test that never returns from the hook leaves precisely that many chunks
    /// behind — an upload interrupted mid-chunks, which no item boundary can reach.
    public static var chunkUploadHook: (@Sendable (_ mediaRecordName: String, _ chunksOnServer: Int) async -> Void)?

    private static let uploadFailureLock = NSLock()
    private static var uploadsBeforeFailure: Int?

    /// Makes the media upload that follows the next `count` uploads throw
    /// `CloudKitMediaStoreError.quotaExceeded` without contacting the server, once;
    /// every later upload goes through. A migration halts on it exactly as on a
    /// full iCloud, with a recoverable failure the user can resume from in the same
    /// launch. `nil` disarms it.
    public static func failUpload(after count: Int?) {
        uploadFailureLock.withLock { uploadsBeforeFailure = count }
    }

    /// Whether this upload is the one `failUpload(after:)` armed. Counts the upload.
    static func consumeUploadFailure() -> Bool {
        uploadFailureLock.withLock {
            guard let remaining = uploadsBeforeFailure else { return false }
            uploadsBeforeFailure = remaining == 0 ? nil : remaining - 1
            return remaining == 0
        }
    }
}
