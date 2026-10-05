//
//  CloudKitAlbumDeleteQueue.swift
//  EncameraCore
//
//  Durable record of CloudKit album deletes the server has not confirmed yet.
//  `AlbumManager.delete` enqueues BEFORE the fire-and-forget delete, so a delete
//  made offline (or killed mid-flight) survives relaunch;
//  `CloudKitAlbumReconciler` drains the queue on every pass and, until an entry
//  drains, refuses to re-materialize that album from its still-live remote record
//  — otherwise the pull path would resurrect a "deleted" album on the deleting
//  device itself.
//
//  The queue holds the local *intent*, independently of how the deletion reaches
//  the server — a real record delete, which cascades to the album's media.
//
//  An entry enqueued with `requiresNoMembers` (a move back to this device that
//  finalized while offline) was meant to delete an album the move had emptied.
//  The reconciler drains such an entry only after `CloudKitAlbumMembership` finds
//  nothing pointing at the album; another device may have added media meanwhile.
//

import Foundation

public struct CloudKitAlbumDeleteQueue: DebugPrintable {

    private static let storageKey = "cloudkit_pending_album_deletes_v1"
    /// The subset of `storageKey` whose delete must wait for an empty membership check.
    private static let requiresNoMembersKey = "cloudkit_pending_album_deletes_requiring_no_members_v1"

    /// `enqueue`/`remove` are read-modify-write over one defaults key, and the two
    /// writers run on different executors (`AlbumManager.delete` on the caller's
    /// thread, the reconciler on the `CloudKitAlbumsSync` actor). Static because
    /// instances are constructed ad hoc around the same underlying key — without a
    /// shared lock an interleaving writes back a stale set and drops the other
    /// side's entry, losing exactly the delete intent this queue exists to keep.
    private static let lock = NSLock()

    private let defaults: UserDefaults

    public init() {
        guard let defaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) else {
            preconditionFailure("No UserDefaults suite named \(UserDefaultUtils.appGroup) — a bundle id cannot be a suite name")
        }
        self.defaults = defaults
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Album ids with an unconfirmed delete.
    public func pending() -> Set<String> {
        let set = Self.lock.withLock { read() }
        printDebug("pending ok count=\(set.count) albumIDs=\(set.sorted())")
        return set
    }

    /// Whether the queued delete of `albumID` may only be issued once nothing
    /// points at the album any more.
    public func requiresNoMembers(_ albumID: String) -> Bool {
        Self.lock.withLock { read(Self.requiresNoMembersKey).contains(albumID) }
    }

    /// Queues the delete of `albumID`. With `requiresNoMembers`, the reconciler
    /// issues it only after a membership check finds the album empty.
    public func enqueue(_ albumID: String, requiresNoMembers: Bool = false) {
        Self.lock.withLock {
            if requiresNoMembers {
                var guarded = read(Self.requiresNoMembersKey)
                if guarded.insert(albumID).inserted {
                    defaults.set(Array(guarded), forKey: Self.requiresNoMembersKey)
                }
            }
            var set = read()
            guard set.insert(albumID).inserted else {
                printDebug("enqueue skip albumID=\(albumID) reason=alreadyQueued pending=\(set.count)")
                return
            }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("enqueue ok albumID=\(albumID) requiresNoMembers=\(requiresNoMembers) pending=\(set.count)")
        }
    }

    public func remove(_ albumID: String) {
        Self.lock.withLock {
            var guarded = read(Self.requiresNoMembersKey)
            if guarded.remove(albumID) != nil {
                defaults.set(Array(guarded), forKey: Self.requiresNoMembersKey)
            }
            var set = read()
            guard set.remove(albumID) != nil else {
                printDebug("remove skip albumID=\(albumID) reason=notQueued pending=\(set.count)")
                return
            }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("remove ok albumID=\(albumID) pending=\(set.count)")
        }
    }

    private func read(_ key: String = Self.storageKey) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}
