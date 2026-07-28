//
//  CloudKitAlbumTombstoneQueue.swift
//  EncameraCore
//
//  Durable record of CloudKit album deletes whose `EncAlbum` tombstone has not
//  been confirmed by the server yet. `AlbumManager.delete` enqueues BEFORE the
//  fire-and-forget tombstone save, so a delete made offline (or killed mid-flight)
//  survives relaunch; `CloudKitAlbumReconciler` drains the queue on every pass
//  and, until an entry drains, refuses to re-materialize that album from its
//  still-live remote record — otherwise the pull path would resurrect a "deleted"
//  album on the deleting device itself.
//

import Foundation

public struct CloudKitAlbumTombstoneQueue: DebugPrintable {

    private static let storageKey = "cloudkit_pending_album_tombstones_v1"

    /// `enqueue`/`remove` are read-modify-write over one defaults key, and the two
    /// writers run on different executors (`AlbumManager.delete` on the caller's
    /// thread, the reconciler on the `CloudKitAlbumsSync` actor). Static because
    /// instances are constructed ad hoc around the same underlying key — without a
    /// shared lock an interleaving writes back a stale set and drops the other
    /// side's entry, losing exactly the delete intent this queue exists to keep.
    private static let lock = NSLock()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard) {
        self.defaults = defaults
    }

    /// Album-id hashes with an unconfirmed tombstone.
    public func pending() -> Set<String> {
        let set = Self.lock.withLock { read() }
        printDebug("pending ok count=\(set.count) albumIDs=\(set.sorted())")
        return set
    }

    public func enqueue(_ albumID: String) {
        Self.lock.withLock {
            var set = read()
            guard set.insert(albumID).inserted else {
                // Already queued: an idempotent re-enqueue, not a lost write.
                printDebug("enqueue skip albumID=\(albumID) reason=alreadyQueued pending=\(set.count)")
                return
            }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("enqueue ok albumID=\(albumID) pending=\(set.count)")
        }
    }

    public func remove(_ albumID: String) {
        Self.lock.withLock {
            var set = read()
            guard set.remove(albumID) != nil else {
                // Removing an entry that isn't there means someone confirmed a
                // tombstone we never recorded — benign, but it hides double-drains.
                printDebug("remove skip albumID=\(albumID) reason=notQueued pending=\(set.count)")
                return
            }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("remove ok albumID=\(albumID) pending=\(set.count)")
        }
    }

    private func read() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }
}
