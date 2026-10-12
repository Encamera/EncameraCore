//
//  DestructiveOnboardingCoordinator.swift
//  EncameraCore
//
//  The destructive "delete my iCloud data" path for the returning user who does
//  NOT have their key. The riskiest flow in the multi-device project: it
//  deletes user data by design and sits directly on the tombstone landmine.
//
//  Non-negotiables, all enforced here:
//   * It deletes iCloud *data*, never keys account-wide. It issues NO account-wide
//     keychain deletion — the user still owns their other device, and an
//     account-wide wipe would tombstone that device's key and brick it.
//   * Deletion is a real record delete, which propagates on the zone change feed
//     so the reconciler cannot resurrect it.
//   * Per-record failures are surfaced, never re-swallowed. A partial failure is
//     reported as such and stops short of clearing the marker or minting a key.
//   * It requires the account to be online, so nothing is attempted that cannot be
//     completed and verified.
//

import Foundation

public enum DestructiveOnboardingError: Error, Equatable {
    /// The CloudKit account is unavailable, so a destructive delete could neither
    /// be completed nor verified. Nothing is attempted.
    case offline
}

/// Machine-readable outcome of the destructive path. Surfaces per-record failures
/// rather than collapsing them, so the UI can report partial failure honestly
/// instead of claiming success.
public struct DestructiveOnboardingReport: Equatable, Sendable {
    public var tombstonedMedia: [String] = []
    public var tombstonedAlbums: [String] = []
    public var removedLegacyFileCount: Int = 0
    /// recordName -> error description for media that could not be tombstoned.
    public var mediaFailures: [String: String] = [:]
    /// albumID -> error description for albums that could not be tombstoned.
    public var albumFailures: [String: String] = [:]
    /// First error hit while removing legacy iCloud Drive files, if any.
    public var legacyFileError: String?
    /// Failures ENUMERATING what to delete, keyed by what was being enumerated
    /// (`"albums"`, or an albumID for its media).
    public var enumerationFailures: [String: String] = [:]
    /// How many live media records the probe's census said this account holds — the
    /// only reason the destructive screen was offered at all.
    public var expectedMediaCount: Int = 0
    /// Records the census counted that the sweep never tombstoned, when a post-sweep
    /// census could not confirm the zone is empty either.
    public var censusShortfall: Int?
    /// Set when clearing the marker fingerprints failed. The one write that
    public var markerClearError: String?
    /// True only when a fresh key was generated — which happens only on a clean run.
    public var freshKeyGenerated: Bool = false

    public var hasFailures: Bool {
        !mediaFailures.isEmpty || !albumFailures.isEmpty || !enumerationFailures.isEmpty
            || legacyFileError != nil || censusShortfall != nil || markerClearError != nil
    }
    public var isCompleteSuccess: Bool { !hasFailures }

    public init() {}
}

/// Removes files left in the DEPRECATED iCloud Drive container. Reuses the same
/// root resolution as the onboarding probe's legacy sweep, which reports a missing
/// ubiquity container as nil rather than a placeholder root.
enum LegacyICloudDriveEraser {
    /// `(removed count, first error description)`. A `nil` container is "nothing to
    /// remove", not a failure: a fresh install not signed into iCloud has no legacy
    /// files to delete, and that must not be reported as a partial failure.
    static func removeAll() async -> (removed: Int, error: String?) {
        guard let root = LegacyICloudDriveSweep.legacyRootURL() else { return (0, nil) }
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, "could not enumerate the legacy iCloud Drive container at \(root.lastPathComponent)")
        }

        var removed = 0
        var firstError: String?
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                if firstError == nil { firstError = "\(error)" }
            }
        }
        return (removed, firstError)
    }
}

/// Runs the destructive delete-my-iCloud-data path end to end. Independent of any
/// UI so both the EncameraCore unit tests and the ENC-72 two-device keychain test
/// can drive it directly.
public struct DestructiveOnboardingCoordinator {

    private let store: CloudKitMediaStoring
    private let keyManager: KeyManager
    private let freshKeyName: String
    private let removeLegacyICloudDriveFiles: @Sendable () async -> (removed: Int, error: String?)

    public init(store: CloudKitMediaStoring,
                keyManager: KeyManager,
                freshKeyName: String = AppConstants.defaultKeyName,
                removeLegacyICloudDriveFiles: (@Sendable () async -> (removed: Int, error: String?))? = nil) {
        self.store = store
        self.keyManager = keyManager
        self.freshKeyName = freshKeyName
        self.removeLegacyICloudDriveFiles = removeLegacyICloudDriveFiles
            ?? { await LegacyICloudDriveEraser.removeAll() }
    }

    /// Tombstones every CloudKit media record and album, removes legacy iCloud
    /// Drive files, and — ONLY on a completely clean run — clears the has-used
    /// marker (preserving the roster) and generates a fresh key. Throws
    /// `.offline` (having attempted nothing) when the account is unavailable;
    /// otherwise always returns a report, whose `isCompleteSuccess` the caller
    /// must check before treating the flow as done.
    ///
    /// `expectedMediaCount` is the probe's live-media census — the census that put
    /// the user on this screen. The sweep is cross-checked against it, so a fetch
    /// that succeeds but comes back short cannot pass for "there was nothing to
    /// delete". Callers with no census pass 0.
    public func run(expectedMediaCount: Int) async throws -> DestructiveOnboardingReport {
        guard await store.accountAvailable() else { throw DestructiveOnboardingError.offline }

        var report = DestructiveOnboardingReport()
        report.expectedMediaCount = expectedMediaCount

        let albums: [CloudKitAlbumMetadata]
        do {
            albums = try await store.fetchAllAlbums()
        } catch {
            report.enumerationFailures["albums"] = "\(error)"
            return report
        }

        var seenRecords = Set<String>()
        for album in albums {
            let media: [CloudKitMediaMetadata]
            do {
                media = try await store.fetchMetadata(albumID: album.albumID, includeThumbnail: false)
            } catch {
                report.enumerationFailures[album.albumID] = "\(error)"
                continue
            }
            for item in media where seenRecords.insert(item.recordName).inserted {
                do {
                    try await store.delete(recordName: item.recordName)
                    report.tombstonedMedia.append(item.recordName)
                } catch {
                    report.mediaFailures[item.recordName] = "\(error)"
                }
            }
        }

        for album in albums {
            do {
                try await store.deleteAlbum(albumID: album.albumID)
                report.tombstonedAlbums.append(album.albumID)
            } catch {
                report.albumFailures[album.albumID] = "\(error)"
            }
        }

        let legacy = await removeLegacyICloudDriveFiles()
        report.removedLegacyFileCount = legacy.removed
        report.legacyFileError = legacy.error

        if report.tombstonedMedia.count < expectedMediaCount, await !zoneConfirmedEmpty() {
            report.censusShortfall = expectedMediaCount - report.tombstonedMedia.count
        }

        guard report.isCompleteSuccess else { return report }

        // Step 6: clear the fingerprints, PRESERVE the roster. A direct overwrite,
        // NOT the merging setter/recorder. An update, not a delete — so the
        // synchronizable record is not tombstoned account-wide.
        let existing = keyManager.getMultiDeviceState()
        do {
            try keyManager.overwriteMultiDeviceState(
                MultiDeviceState(devices: existing?.devices ?? [],
                                 keyFingerprints: [])
            )
        } catch {
            report.markerClearError = "\(error)"
            return report
        }

        _ = try keyManager.generateKeyUsingRandomWords(name: freshKeyName)
        report.freshKeyGenerated = true

        return report
    }

    /// Whether a post-sweep census can positively confirm the zone holds no live
    /// media. An unavailable index or an unclassified throw is NOT a confirmation:
    /// this is the same evidence-vs-absence distinction `ExistingDataProbe` makes,
    /// applied to the verification of a delete rather than the detection of data.
    private func zoneConfirmedEmpty() async -> Bool {
        do {
            guard case .counted(let mediaCount, _) = try await store.fetchFingerprintCensus() else {
                return false
            }
            return mediaCount == 0
        } catch CloudKitMediaStoreError.zoneNotFound {
            return true
        } catch {
            return false
        }
    }
}
