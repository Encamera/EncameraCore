//
//  CloudKitZoneWalkRequests.swift
//  EncameraCore
//
//  The CloudKit albums whose index was created by something other than the
//  sync, and so may lack records that reached the zone before this device knew
//  the album. The sync coordinator walks the whole zone for an album without an
//  index; an album named here is walked the same way, and leaves the list once a
//  whole-zone walk has applied to it. Kept in the app group defaults, so a
//  request survives the process.
//

import Foundation

public struct CloudKitZoneWalkRequests: DebugPrintable {

    private static let storageKey = "cloudkit_zone_walk_requests_v1"
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

    /// The album ids waiting for a whole-zone walk.
    public func requested() -> Set<String> {
        Self.lock.withLock { read() }
    }

    /// Asks for a whole-zone walk before the album's next delta sync.
    public func request(_ albumID: String) {
        Self.lock.withLock {
            var set = read()
            guard set.insert(albumID).inserted else { return }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("request ok albumID=\(albumID) requested=\(set.count)")
        }
    }

    /// Drops the requests a whole-zone walk has answered.
    public func clear(_ albumIDs: Set<String>) {
        Self.lock.withLock {
            var set = read()
            let before = set.count
            set.subtract(albumIDs)
            guard set.count != before else { return }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("clear ok cleared=\(before - set.count) requested=\(set.count)")
        }
    }

    private func read() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }
}
