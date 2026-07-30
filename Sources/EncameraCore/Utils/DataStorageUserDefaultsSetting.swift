//
//  ImageKeyDirectoryStorage.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation

public struct DataStorageAvailabilityUtil {

    public static var preselectedStorageSetting: StorageAvailabilityModel? {
        storageAvailabilities().filter({$0.availability == .available}).first
    }

    /// Whether the storage backend is usable on this device *right now* — i.e. whether
    /// existing albums there can be enumerated, read, written to, and deleted.
    ///
    /// This is deliberately NOT the same question as "may a new album be put here":
    /// iCloud Drive is deprecated as a destination, but the albums a user already has
    /// in iCloud Drive must keep showing up in the album list — and stay fully
    /// writable — until they migrate them (ENC-106). Destination eligibility lives in
    /// `isStorageTypeOfferedForNewAlbums` and the pickers that read it.
    ///
    /// Gating a save, enumerate, count, preview, delete or migrate path on the
    /// destination question instead of this one is a silent failure: it strands users
    /// on the iCloud Drive albums they already have, and nothing goes red without
    /// `ICloudDriveLegacyContractTests`.
    public static func isStorageTypeAvailable(type: StorageType) -> StorageType.Availability {
        switch type {
        case .icloud:
            // A substituted container root stands in for the ubiquity token: it is the
            // same question ("is there a container to read from"), and without this a
            // simulator — which never has a token — could not exercise the legacy
            // albums that must keep working. Nil outside tests. It is also what keeps
            // callers out of `iCloudStorageModel.rootURL`'s `fatalError`.
            if iCloudStorageModel.testContainerRootOverride == nil,
               FileManager.default.ubiquityIdentityToken == nil {
                return .unavailable(reason: L10n.noICloudAccountFoundOnThisDevice)
            }
            return .available
        case .local:
            return .available
        case .cloudKit:
            // Offered only when the feature flag is on AND an iCloud account is
            // present. A CloudKit account implies the ubiquity token exists, so we
            // reuse that synchronous signal (same one iCloud Drive checks) rather
            // than threading async account-status through every availability site.
            guard FeatureToggle.isEnabled(feature: .cloudKitStorage) else {
                return .unavailable(reason: "CloudKit storage is not enabled")
            }
            // UI tests force account availability so the picker can be exercised
            // offline (the in-memory mock store backs the coordinator). Gated on
            // -UITestMode like every other test hook, so the flag stays inert in
            // production — without it, a stray argument would offer CloudKit with
            // no iCloud account and every subsequent save would fail.
            let arguments = ProcessInfo.processInfo.arguments
            let accountForcedAvailable = arguments.contains("-UITestMode")
                && arguments.contains("-CloudKitAccountAvailable")
            if !accountForcedAvailable, FileManager.default.ubiquityIdentityToken == nil {
                return .unavailable(reason: L10n.noICloudAccountFoundOnThisDevice)
            }
            return .available
        }
    }
    
    /// Whether a *new* album may be created in (or moved into) this storage type.
    ///
    /// Narrower than `isStorageTypeAvailable`: iCloud Drive is a dead end, so it is
    /// never offered as a destination even though its existing albums stay fully
    /// readable and writable. `AlbumManager.create`/`moveAlbum` enforce the same rule
    /// as the authoritative backstop.
    ///
    /// The only legitimate callers are the ones answering "may we put NEW data here":
    /// the storage picker list (`storageAvailabilities`) and the migration prompt
    /// asking whether its CloudKit destination is offerable.
    public static func isStorageTypeOfferedForNewAlbums(type: StorageType) -> StorageType.Availability {
        if type == .icloud {
            // Unconditional, not gated on `cloudKitStorage`. The flag governs whether
            // CloudKit is *offered*; it must not govern whether iCloud Drive is
            // deprecated, or release builds would keep minting new Drive albums while
            // the replacement is still behind the flag.
            return .unavailable(reason: "iCloud Drive storage is deprecated")
        }
        return isStorageTypeAvailable(type: type)
    }

    /// The destination options shown by the storage pickers, so every picker inherits
    /// the iCloud Drive deprecation rule from one place.
    public static func storageAvailabilities() -> [StorageAvailabilityModel] {
        var availabilites = [StorageAvailabilityModel]()
        for type in StorageType.allCases {
            let result = isStorageTypeOfferedForNewAlbums(type: type)
            availabilites += [StorageAvailabilityModel(storageType: type, availability: result)]
        }
        return availabilites
    }
}
