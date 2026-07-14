//
//  CloudKitContainer.swift
//  EncameraCore
//
//  Provisioning-only accessor for the Encamera CloudKit container: account-status
//  gating and idempotent custom-zone creation. Performs NO media I/O — that is
//  chunk 02. See plans/cloudkit-migration/01-cloudkit-foundations.md.
//

import Foundation
import CloudKit

// MARK: - Injectable seams (so tests never touch a live iCloud account)

/// Supplies the CloudKit account status. Backed by `CKContainer` in production,
/// stubbed in tests.
public protocol AccountStatusProviding {
    func currentAccountStatus() async throws -> CKAccountStatus
}

extension CKContainer: AccountStatusProviding {
    public func currentAccountStatus() async throws -> CKAccountStatus {
        try await accountStatus()
    }
}

/// Creates a custom record zone. Backed by `CKDatabase` in production, mocked in
/// tests so the idempotency contract can be verified offline.
public protocol RecordZoneProvisioning {
    func saveZone(_ zone: CKRecordZone) async throws
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws
}

extension CKDatabase: RecordZoneProvisioning {
    public func saveZone(_ zone: CKRecordZone) async throws {
        _ = try await modifyRecordZones(saving: [zone], deleting: [])
    }

    public func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        _ = try await modifyRecordZones(saving: [], deleting: [zoneID])
    }
}

// MARK: - Container

/// Thin, defensive accessor for the app's CloudKit private database.
///
/// Mirrors the posture of `DataStorageAvailabilityUtil.isStorageTypeAvailable`
/// (which checks `ubiquityIdentityToken`): if there is no usable iCloud account,
/// CloudKit is reported unavailable and the app stays on local-only. We never
/// crash and never block on a missing account.
public final class CloudKitContainer {

    /// Shared instance wired to the real container.
    public static let shared = CloudKitContainer()

    /// The real CloudKit container for this app.
    public static var defaultContainer: CKContainer {
        CKContainer(identifier: CloudKitSchema.containerID)
    }

    private let accountStatusProvider: AccountStatusProviding
    private let zoneProvisioner: RecordZoneProvisioning
    private let defaults: UserDefaults

    /// Persisted in the app-group defaults (same store `SyncedDataStore` uses) so
    /// we don't re-issue the zone-create op on every launch. Keyed by the container
    /// identifier: the zone lives inside a specific container, so a flag set for one
    /// container must NOT suppress creation in another (e.g. after the container id
    /// changes, or Debug vs Release). A global key let a stale "created" flag leave
    /// the new container with no zone.
    private var zoneCreatedKey: String { "cloudkit_zone_created_v1_" + CloudKitSchema.containerID }

    public init(
        accountStatusProvider: AccountStatusProviding = CloudKitContainer.defaultContainer,
        zoneProvisioner: RecordZoneProvisioning = CloudKitContainer.defaultContainer.privateCloudDatabase,
        defaults: UserDefaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard
    ) {
        self.accountStatusProvider = accountStatusProvider
        self.zoneProvisioner = zoneProvisioner
        self.defaults = defaults
    }

    // MARK: Accessors

    public var container: CKContainer { CloudKitContainer.defaultContainer }
    public var privateDB: CKDatabase { container.privateCloudDatabase }
    public var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: CloudKitSchema.zoneName) }

    // MARK: Account status

    /// Resolves the account status, never throwing — any error collapses to
    /// `.couldNotDetermine` (treated as unavailable).
    public func accountStatus() async -> CKAccountStatus {
        do {
            return try await accountStatusProvider.currentAccountStatus()
        } catch {
            return .couldNotDetermine
        }
    }

    /// CloudKit is usable only when an account is fully available. `.noAccount`,
    /// `.restricted`, and `.couldNotDetermine` all mean "stay local-only".
    public func isCloudKitAvailable() async -> Bool {
        await accountStatus() == .available
    }

    // MARK: Zone bootstrap

    /// Idempotently ensures the custom `EncameraZone` exists. Cheap no-op after the
    /// first success (guarded by a persisted flag). Tolerates "already exists"
    /// races so concurrent launches don't surface a spurious error.
    public func ensureZoneExists() async throws {
        if defaults.bool(forKey: zoneCreatedKey) { return }

        let zone = CKRecordZone(zoneName: CloudKitSchema.zoneName)
        do {
            try await zoneProvisioner.saveZone(zone)
        } catch {
            guard Self.isBenignZoneError(error) else { throw error }
        }
        defaults.set(true, forKey: zoneCreatedKey)
    }

    /// Resets the cached "zone created" flag (used by migration/teardown paths).
    public func resetZoneCreatedFlag() {
        defaults.set(false, forKey: zoneCreatedKey)
    }

    // MARK: Teardown

    /// Deletes the entire `EncameraZone` from the private database — in one server
    /// operation this removes every `EncMedia` and `EncAlbum` record and all of
    /// their CKAssets. Used by the "Erase All Data" reset to wipe the user's
    /// CloudKit data across all of their devices.
    ///
    /// A zone that does not exist (user never used CloudKit, or already deleted on
    /// another device) is treated as success — there is nothing to remove. Any
    /// other failure (e.g. offline, no account) is surfaced so the caller can warn
    /// that iCloud data may remain.
    public func deleteAllCloudData() async throws {
        do {
            try await zoneProvisioner.deleteZone(zoneID)
        } catch {
            guard Self.isBenignDeleteError(error) else { throw error }
        }
        resetZoneCreatedFlag()
    }

    /// Deleting a zone that is already gone is harmless; treat the corresponding
    /// CloudKit errors as success.
    static func isBenignDeleteError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .zoneNotFound, .userDeletedZone:
            return true
        case .partialFailure:
            let perItem: [AnyHashable: Error] = ckError.partialErrorsByItemID ?? [:]
            return !perItem.isEmpty && perItem.values.allSatisfy { isBenignDeleteError($0) }
        default:
            return false
        }
    }

    /// Creating a zone that already exists is harmless; treat the corresponding
    /// CloudKit errors as success so the flag still gets set.
    static func isBenignZoneError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .serverRecordChanged:
            return true
        case .partialFailure:
            let perItem: [AnyHashable: Error] = ckError.partialErrorsByItemID ?? [:]
            // Benign only if there is at least one underlying failure and every
            // one of them is itself benign.
            return !perItem.isEmpty && perItem.values.allSatisfy { isBenignZoneError($0) }
        default:
            return false
        }
    }
}
