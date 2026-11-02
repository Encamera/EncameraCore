//
//  BlobMigrationOrder.swift
//  EncameraCore
//
//  The one ordering function over an album's iCloud Drive migration items. The
//  order is a pure function of each item's stored attributes, the device state and
//  this device's seed, so it is deterministic and the same after a relaunch.
//

import CryptoKit
import Foundation

/// The device state the migration order depends on.
public struct BlobMigrationDeviceState: Sendable, Equatable {
    /// Whether protected data is available. Encrypting items are eligible only then.
    public var isUnlocked: Bool

    public init(isUnlocked: Bool) {
        self.isUnlocked = isUnlocked
    }

    public static let locked = BlobMigrationDeviceState(isUnlocked: false)
    public static let unlocked = BlobMigrationDeviceState(isUnlocked: true)
}

/// Orders the items an album still has to migrate. Nothing else decides what runs
/// next, and nothing reorders items by hand: a user request is recorded with
/// `MigrationPlanStore.prioritize` (or `prioritizeViewed` for an open in the
/// viewer or player), and locking or unlocking only changes which tiers are
/// eligible.
///
/// Tiers, in order:
/// 1. Items requested with `.userAction`, in request order.
/// 2. Items requested with `.viewed`, most recently viewed first.
/// 3. Encrypting items, in this device's seed order.
/// 4. Ciphertext-only items, in this device's seed order.
/// 5. Deferred items (those with a `deferralReason`), in this device's seed
///    order. A request does not lift an item out of it. No Wi-Fi check is
///    needed here: a pass runs only on Wi-Fi.
///    A viewed open that decrypted the item clears every reason but
///    `.recordInAnotherAlbum` (`MigrationPlan.prioritizeViewed`), which moves
///    it to tier 2.
///
/// Tiers 1 and 2 never use the seed: items tied on their request time run in
/// `mediaID` order. In tiers 3 to 5 the seed is the primary order, so devices
/// working through the same album start on different items; items with equal
/// seeds run most recent `createdAt` first, then in `mediaID` order. With the
/// default seed of 0 for every item, tiers 3 to 5 run most recent first.
///
/// While locked, no encrypting item is returned from any tier, including a
/// requested or deferred one: plaintext is never written while locked. The two
/// halves of a Live Photo (items sharing a `mediaID`) stay adjacent, in the best
/// tier either eligible half qualifies for. Items whose state is done are not
/// returned.
public enum BlobMigrationOrder {

    /// The eligible items of `items` in the order they should run.
    ///
    /// `seed` maps a `mediaID` to this device's order within the encrypting,
    /// ciphertext-only and deferred tiers, smallest first (`deviceSeed()` in
    /// production).
    public static func next(items: [MigrationItem],
                            deviceState: BlobMigrationDeviceState,
                            seed: (_ mediaID: String) -> UInt64 = { _ in 0 }) -> [MigrationItem] {
        let eligible = items.filter { item in
            !item.state.isDone
                && (deviceState.isUnlocked || item.kind != .encrypting)
        }
        let groups = Dictionary(grouping: eligible, by: \.mediaID).map { mediaID, members in
            Group(mediaID: mediaID,
                  members: members.sorted { $0.recordName < $1.recordName },
                  seed: seed(mediaID))
        }
        return groups.sorted(by: Group.runsBefore).flatMap(\.members)
    }

    private enum Tier: Int, Comparable {
        case userRequested, viewed, encrypting, ciphertextOnly, deferred

        init(_ item: MigrationItem) {
            if item.deferralReason != nil {
                self = .deferred
                return
            }
            switch (item.priorityRequest?.reason, item.kind) {
            case (.userAction?, _): self = .userRequested
            case (.viewed?, _): self = .viewed
            case (nil, .encrypting): self = .encrypting
            case (nil, .ciphertextOnly): self = .ciphertextOnly
            }
        }

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One media item's eligible components, ranked by the best of them.
    private struct Group {
        let mediaID: String
        let members: [MigrationItem]
        let seed: UInt64
        let tier: Tier
        /// The tier's sort key, larger first.
        let key: Double

        init(mediaID: String, members: [MigrationItem], seed: UInt64) {
            self.mediaID = mediaID
            self.members = members
            self.seed = seed
            let tier = members.map(Tier.init).min() ?? .ciphertextOnly
            self.tier = tier
            let inTier = members.filter { Tier($0) == tier }
            switch tier {
            case .userRequested:
                // Earliest request first.
                let first = inTier.compactMap(\.priorityRequest?.requestedAt).min() ?? .distantPast
                key = -first.timeIntervalSinceReferenceDate
            case .viewed:
                let latest = inTier.compactMap(\.priorityRequest?.requestedAt).max() ?? .distantPast
                key = latest.timeIntervalSinceReferenceDate
            case .encrypting, .ciphertextOnly, .deferred:
                key = (inTier.map(\.createdAt).max() ?? .distantPast).timeIntervalSinceReferenceDate
            }
        }

        static func runsBefore(_ lhs: Group, _ rhs: Group) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            switch lhs.tier {
            case .userRequested, .viewed:
                break
            case .encrypting, .ciphertextOnly, .deferred:
                if lhs.seed != rhs.seed { return lhs.seed < rhs.seed }
            }
            if lhs.key != rhs.key { return lhs.key > rhs.key }
            return lhs.mediaID < rhs.mediaID
        }
    }

    // MARK: - Device seed

    /// This device's seed function: `seed(deviceID:mediaID:)` under
    /// `DeviceIdentity.current`, read once.
    public static func deviceSeed(deviceID: String = DeviceIdentity.current) -> @Sendable (_ mediaID: String) -> UInt64 {
        { mediaID in seed(deviceID: deviceID, mediaID: mediaID) }
    }

    /// The first 8 bytes, big-endian, of SHA-256 over the UTF-8 of
    /// `deviceID + mediaID`. The same in every process and on every launch, unlike
    /// `Hasher`, which is seeded per process.
    public static func seed(deviceID: String, mediaID: String) -> UInt64 {
        let digest = SHA256.hash(data: Data((deviceID + mediaID).utf8))
        return digest.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
