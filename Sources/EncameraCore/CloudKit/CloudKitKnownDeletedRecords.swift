//
//  CloudKitKnownDeletedRecords.swift
//  EncameraCore
//
//  The session half of `CloudKitMediaDeleteQueue`, one instance per storage
//  suite: the record names a delete has claimed on this device, and the claim
//  each one is currently held under.
//
//  Reads fail closed on a marked name, so a delete that lands mid-fetch wins
//  instead of the fetched copy. The claim is what makes confirming a delete a
//  compare-and-clear: a confirmation can only drop the intent it was issued for,
//  never a newer one for a record that has since been republished and deleted
//  again.
//
//  Process-wide for the same reason the queue is: an album can be served by more
//  than one coordinator at a time — the registry's long-lived instance and the
//  private one `CloudKitMigrationManager` builds for a move back into iCloud —
//  and the coordinator that republishes a record name is not the one that marked
//  it. Held per instance, the mark a move OUT of iCloud left behind outlived the
//  move back, and the registry coordinator refused to read a photo that was live
//  again. Keyed by suite name so that the queue and the marks for one storage
//  suite can never come apart: same suite, same instance, always.
//
//  Deliberately NOT persisted, unlike the queue. This is a within-session race
//  guard, not an intent: the durable half is the queue, a mark is only ever
//  dropped (never acted on), and persisting one per deleted record would grow a
//  defaults key without bound for state a relaunch is entitled to forget.
//

import Foundation

/// Identifies one claim on a record's delete. Held by the claimant and presented
/// back when the server confirms, so a confirmation that arrives after the record
/// was republished and re-deleted cannot clear the newer claim's intent.
struct CloudKitDeleteClaim: Equatable, Sendable {
    let generation: UInt64
}

final class CloudKitKnownDeletedRecords: @unchecked Sendable {

    /// One instance per suite name, so two `CloudKitMediaDeleteQueue`s over the
    /// same durable storage always share the same session state. Isolating one
    /// half while inheriting the other shared is the split the pairing exists to
    /// prevent, and this is what makes it unrepresentable rather than merely
    /// discouraged. Instances live for the process — one of them in the app; a
    /// test suite name adds an empty one costing a dictionary entry.
    private static let registryLock = NSLock()
    private static var bySuite: [String: CloudKitKnownDeletedRecords] = [:]

    static func forSuite(_ suiteName: String) -> CloudKitKnownDeletedRecords {
        registryLock.withLock {
            if let existing = bySuite[suiteName] { return existing }
            let created = CloudKitKnownDeletedRecords()
            bySuite[suiteName] = created
            return created
        }
    }

    /// The production instance, paired with the app-group defaults.
    static var shared: CloudKitKnownDeletedRecords { forSuite(UserDefaultUtils.appGroup) }

    /// Coordinators are separate actors, so this is read and written from several
    /// executors at once. Always the INNER lock: the queue takes its own static
    /// lock first for anything that touches both halves.
    private let lock = NSLock()
    private var names: Set<String> = []
    /// Bumped on every claim and every republish, so a stale confirmation cannot
    /// match. Absent means "never claimed this session", which is generation 0 —
    /// what a queue entry restored from a previous launch is claimed under.
    private var generations: [String: UInt64] = [:]
    /// Record names with a claim that has been neither released nor confirmed.
    /// `clearKnownDeletedIfNotQueued` leaves these marked: the delete they stand
    /// for has not finished, so a fetched copy must not win over it.
    private var activeClaims: Set<String> = []
    /// Claims that stay active after their delete is confirmed, until the record
    /// is republished. Taken for an item deleted while its upload may still be in
    /// flight: the upload's save can land after the delete is confirmed, and the
    /// mark is what makes that upload reclaim its record instead of keeping it.
    private var claimsHeldPastConfirmation: Set<String> = []
    /// Record names a drain has a server delete in flight for, and the
    /// republishes waiting for that delete to finish before they upload.
    private var deletesInFlight: Set<String> = []
    private var inFlightWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private init() {}

    func contains(_ recordName: String) -> Bool {
        lock.withLock { names.contains(recordName) }
    }

    /// Marks the record and takes the next claim on it.
    ///
    /// - Parameter holdPastConfirmation: keep the claim active after `retire`, so
    ///   only a republish (`release`) lets a fetched copy unmark the record.
    func claim(_ recordName: String, holdPastConfirmation: Bool = false) -> CloudKitDeleteClaim {
        lock.withLock {
            names.insert(recordName)
            activeClaims.insert(recordName)
            if holdPastConfirmation {
                claimsHeldPastConfirmation.insert(recordName)
            } else {
                claimsHeldPastConfirmation.remove(recordName)
            }
            let next = (generations[recordName] ?? 0) + 1
            generations[recordName] = next
            return CloudKitDeleteClaim(generation: next)
        }
    }

    /// The claim a queued record is currently held under, for a drain that did not
    /// issue the claim itself.
    func currentClaim(_ recordName: String) -> CloudKitDeleteClaim {
        lock.withLock { CloudKitDeleteClaim(generation: generations[recordName] ?? 0) }
    }

    /// Whether `claim` is still the live claim on the record.
    func isCurrent(_ claim: CloudKitDeleteClaim, for recordName: String) -> Bool {
        lock.withLock { (generations[recordName] ?? 0) == claim.generation }
    }

    /// Unmarks the record and retires every outstanding claim on it, because the
    /// record is live again.
    func release(_ recordName: String) {
        lock.withLock {
            names.remove(recordName)
            activeClaims.remove(recordName)
            claimsHeldPastConfirmation.remove(recordName)
            guard let current = generations[recordName] else { return }
            generations[recordName] = current + 1
        }
    }

    /// Ends `claim` once the server has confirmed its delete, unless it was taken
    /// with `holdPastConfirmation`. The record stays marked; only the claim stops
    /// counting as active. A superseded claim changes nothing.
    func retire(_ claim: CloudKitDeleteClaim, for recordName: String) {
        lock.withLock {
            guard (generations[recordName] ?? 0) == claim.generation,
                  !claimsHeldPastConfirmation.contains(recordName) else { return }
            activeClaims.remove(recordName)
        }
    }

    /// Whether `recordName` has a claim this session that has been neither
    /// released nor retired. Used by `clearKnownDeletedIfNotQueued`, so a record
    /// whose delete is still in progress is not unmarked by a fetched copy.
    func hasActiveClaim(_ recordName: String) -> Bool {
        lock.withLock { activeClaims.contains(recordName) }
    }

    /// Inserts `recordName` into `names` without touching `generations`. Used for
    /// feed-observed deletes that need reads to fail closed but must not bump the
    /// claim generation — a bump would strand an in-flight local delete whose
    /// `confirmDelete(claimedAs:)` still holds the previous generation.
    func markOnly(_ recordName: String) {
        lock.withLock { names.insert(recordName) }
    }

    /// Unmarks without retiring the claim, for the sync paths that learn from the
    /// server that a record is live.
    func unmark(_ recordName: String) {
        lock.withLock { _ = names.remove(recordName) }
    }

    /// Marks a server delete of `recordName` as in flight. False when one already is.
    func beginDeleteInFlight(_ recordName: String) -> Bool {
        lock.withLock { deletesInFlight.insert(recordName).inserted }
    }

    /// Clears the in-flight mark and hands back the waiters for the caller to
    /// resume once it has dropped every lock.
    func endDeleteInFlight(_ recordName: String) -> [CheckedContinuation<Void, Never>] {
        lock.withLock {
            deletesInFlight.remove(recordName)
            return inFlightWaiters.removeValue(forKey: recordName) ?? []
        }
    }

    /// Parks `waiter` until the delete in flight for `recordName` ends. False,
    /// with the waiter left unparked, when no delete is in flight.
    func waitForDeleteInFlight(_ recordName: String, _ waiter: CheckedContinuation<Void, Never>) -> Bool {
        lock.withLock {
            guard deletesInFlight.contains(recordName) else { return false }
            inFlightWaiters[recordName, default: []].append(waiter)
            return true
        }
    }

    /// Empties everything. For tests: an instance outlives every one of them, so a
    /// name one test marks would otherwise make another test's read of the same
    /// name fail closed.
    func removeAll() {
        lock.withLock {
            names.removeAll()
            generations.removeAll()
            activeClaims.removeAll()
            claimsHeldPastConfirmation.removeAll()
            deletesInFlight.removeAll()
            inFlightWaiters.values.joined().forEach { $0.resume() }
            inFlightWaiters.removeAll()
        }
    }
}
