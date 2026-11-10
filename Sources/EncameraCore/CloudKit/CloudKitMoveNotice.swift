//
//  CloudKitMoveNotice.swift
//  EncameraCore
//
//  A one-time notice, per album, that the album's move into or out of CloudKit
//  has finished. It is recorded where the move finishes, which can be in the
//  background or while the phone is locked, and read by the album screen, which
//  shows it once and clears it when the user dismisses it.
//

import Foundation

/// Which move finished.
public enum CloudKitMoveNoticeKind: String, Codable, Sendable {
    /// The album moved from iCloud Drive to CloudKit.
    case upgradedFromICloudDrive
    /// The album moved from This Device to CloudKit.
    case movedFromThisDevice
    /// The album moved from CloudKit to This Device.
    case movedToThisDevice
}

/// Pending move-complete notices, keyed by `key(for:)`. Kept in this
/// device's app-group defaults only, never synced: only the device that ran the
/// move shows the notice. Reads no keychain item, so it works while locked.
public enum CloudKitMoveNotice: DebugPrintable {

    static let storageKey = "cloudkit_move_notices_v1"
    private static let lock = NSLock()

    /// The defaults the notices live in. Tests substitute their own.
    nonisolated(unsafe) static var defaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) else {
            preconditionFailure("No UserDefaults suite named \(UserDefaultUtils.appGroup) — a bundle id cannot be a suite name")
        }
        return defaults
    }()

    /// The key an album's notice is kept under: its CloudKit album id, or for a
    /// local album its `Album.id`. An iCloud Drive album has none.
    public static func key(for album: Album) -> String? {
        switch album.storageOption {
        case .cloudKit: return album.albumID
        case .local: return album.id
        case .icloud: return nil
        }
    }

    /// Records that the move of the album keyed `albumID` finished. A later mark for
    /// the same album replaces the kind.
    public static func markPending(albumID: String, kind: CloudKitMoveNoticeKind) {
        lock.withLock {
            var notices = read()
            notices[albumID] = kind.rawValue
            defaults.set(notices, forKey: storageKey)
        }
        printDebug("markPending albumID=\(albumID) kind=\(kind.rawValue)")
    }

    /// The notice waiting to be shown for `albumID`, if any.
    public static func pending(albumID: String) -> CloudKitMoveNoticeKind? {
        lock.withLock { read()[albumID].flatMap(CloudKitMoveNoticeKind.init(rawValue:)) }
    }

    /// Forgets the notice for `albumID`: shown and dismissed, or the album is gone.
    public static func clear(albumID: String) {
        let removed: Bool = lock.withLock {
            var notices = read()
            guard notices.removeValue(forKey: albumID) != nil else { return false }
            defaults.set(notices, forKey: storageKey)
            return true
        }
        if removed {
            printDebug("clear albumID=\(albumID)")
        }
    }

    /// Moves a pending notice from one key to another, when a local album is
    /// renamed and so changes its `Album.id`.
    public static func carry(from oldKey: String, to newKey: String) {
        guard oldKey != newKey else { return }
        lock.withLock {
            var notices = read()
            guard let kind = notices.removeValue(forKey: oldKey) else { return }
            notices[newKey] = kind
            defaults.set(notices, forKey: storageKey)
        }
    }

    /// Forgets every notice, when this device's data is erased.
    public static func clearAll() {
        lock.withLock { defaults.removeObject(forKey: storageKey) }
    }

    private static func read() -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
}
