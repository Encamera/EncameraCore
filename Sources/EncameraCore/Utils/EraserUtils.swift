//
//  EraserUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation

/// What an erase removes. Both scopes wipe the keychain account-wide: a synced
/// passcode hash left in iCloud Keychain sends onboarding straight back to
/// "enter existing passcode", so nothing short of that gets a user past it.
public enum ErasureScope {
    /// Pre-auth reset from the lock screen and onboarding: everything except the
    /// encrypted media (`ErasureTier.reset`). The user gets the media back by
    /// entering their key phrases in onboarding.
    case reset
    /// Settings "Erase All Data", behind an unlock: the reset plus the encrypted
    /// media, locally and in iCloud (`ErasureTier.ciphertext`).
    case allData

    public var screenName: String {
        switch self {
        case .reset:
            return "reset"
        case .allData:
            return "all_data"
        }
    }
}

/// The CloudKit teardown EraserUtils needs, expressed as a seam so tests can
/// verify "Erase All Data" without touching a live iCloud account.
public protocol CloudDataErasing {
    func deleteAllCloudData() async throws
    /// Removes every subscription in the private database; a zone delete does
    /// not take the zone subscription with it.
    func deleteAllSubscriptions() async throws
    /// Owned zone names still present on the server after `deleteAllCloudData`.
    func remainingZoneNames() async throws -> [String]
    func remainingSubscriptionIDs() async throws -> [String]
    /// Whether the user could actually have CloudKit data — this device provisioned
    /// the zone, or an iCloud account is currently signed in. Gates the "iCloud data
    /// may remain" warning so a purely local, signed-out user never sees an
    /// unactionable false positive after a failed (irrelevant) zone delete.
    func mayHaveCloudKitData() async -> Bool
}

extension CloudKitContainer: CloudDataErasing {
    public func mayHaveCloudKitData() async -> Bool {
        if hasEverProvisionedZone { return true }
        return await isCloudKitAvailable()
    }
}

/// The local wipe steps, expressed as a seam so tests can verify the erase
/// sequence — each step independent, all steps running even when the cloud
/// delete fails — without wiping the test process's real defaults, keychain,
/// and filesystem.
public protocol LocalDataErasing {
    /// Cancels all in-flight CloudKit syncs, uploads, and blob downloads so the
    /// zone delete is the only CloudKit operation in flight. Must run before
    /// `deleteAllCloudData`.
    func shutdownCloudKitSync() async
    /// Halts in-flight CloudKit migrations (no further checkpoints or CloudKit
    /// ops) and removes the on-disk migration checkpoints.
    func eraseMigrationState() async
    /// Active backend cleanup (also clears that backend's in-memory caches).
    func eraseActiveBackendMedia() async
    /// Global sweep across every storage type, independent of the active album.
    /// Excludes iCloud Drive — that is handled by `eraseICloudDriveMedia`.
    func eraseAllLocalMediaFiles()
    /// iCloud Drive album files and the ubiquity container's Documents tree.
    func eraseICloudDriveMedia()
    /// Per-album encrypted media indexes.
    func eraseMediaIndexes()
    /// Local CloudKit blob cache (encrypted, evictable copies).
    func eraseBlobCache() async
    /// Decrypted preview thumbnails.
    func eraseThumbnails()
    /// Temp directories that can hold decrypted cleartext.
    func eraseTempDirectories()
    /// The App Group container's import directory, plus any pending-import state.
    func eraseSharedContainerImports() async
    /// Everything left in the app's own container trees, whatever put it there.
    ///
    /// MUST only run on a path that then terminates the app. The sweep includes
    /// `Library/Caches/CloudKit`, and removing that under a running `cloudd` does
    /// not merely discard cached assets — the next fetch fails with
    /// `chunkNotFound` for a record that exists (measured on device, 26 Aug 2026).
    /// `PromptToErase` calls `exit(0)` immediately afterwards, so CloudKit rebuilds
    /// on the next launch; a caller that erased and carried on would break every
    /// CloudKit read for the rest of the session.
    func eraseResidualContainerFiles()
    func eraseKeychain()
    func eraseUserDefaults()
    /// Durably records that a cloud wipe is still owed (written AFTER the defaults
    /// wipe so it survives it); the app retries on launch until it succeeds.
    func recordPendingCloudWipe()
}

/// Production implementation of the local wipe steps.
struct DefaultLocalDataEraser: LocalDataErasing, DebugPrintable {

    let keyManager: KeyManager
    let fileAccess: FileAccess

    func shutdownCloudKitSync() async {
        await CloudKitUploader.shared.shutdown()
        await CloudKitCoordinatorRegistry.shared.shutdownAll()
        printDebug("EraserUtils: CloudKit sync infrastructure shut down")
    }

    func eraseMigrationState() async {
        await MainActor.run { CloudKitMigrationManager.requestAbortAll() }
        do {
            try MigrationPlanStore.clearAllPlans()
        } catch {
            printDebug("EraserUtils: could not clear migration plans: \(error)")
        }
    }

    func eraseActiveBackendMedia() async {
        do {
            try await fileAccess.deleteAllMedia()
        } catch {
            printDebug("EraserUtils: could not delete active backend media: \(error)")
        }
    }

    /// Deletes every local album tree across non-iCloud storage types, regardless
    /// of which album's backend is currently configured. iCloud Drive is handled
    /// separately by `eraseICloudDriveMedia`.
    func eraseAllLocalMediaFiles() {
        for type in StorageType.allCases where type != .icloud {
            guard case .available = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: type) else {
                continue
            }
            do {
                try type.modelForType.deleteAllFiles()
            } catch {
                printDebug("EraserUtils: could not delete all files for \(type): \(error)")
            }
        }
    }

    func eraseICloudDriveMedia() {
        guard let ubiquityRoot = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            printDebug("EraserUtils: ubiquity container unavailable — cannot clean iCloud Drive")
            return
        }
        if case .available = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) {
            do {
                try StorageType.icloud.modelForType.deleteAllFiles()
            } catch {
                printDebug("EraserUtils: could not delete iCloud Drive album files: \(error)")
            }
        }
        let documents = ubiquityRoot.appendingPathComponent("Documents")
        let albums = documents.appendingPathComponent("albums")
        for target in [albums, documents] {
            do {
                try FileManager.default.removeItem(at: target)
                printDebug("EraserUtils: removed ubiquity \(target.lastPathComponent)")
            } catch {
                printDebug("EraserUtils: could not remove ubiquity \(target.lastPathComponent): \(error)")
            }
        }
    }

    func eraseMediaIndexes() {
        do {
            try MediaIndexStore.clearAllIndexes()
        } catch {
            printDebug("EraserUtils: could not clear media indexes: \(error)")
        }
    }

    func eraseBlobCache() async {
        do {
            try await CloudKitBlobCache.shared.clearAll()
        } catch {
            printDebug("EraserUtils: could not clear blob cache: \(error)")
        }
        do {
            try await CloudKitUploadQueue.shared.clearAll()
        } catch {
            printDebug("EraserUtils: could not clear the pending upload queue: \(error)")
        }
    }

    func eraseThumbnails() {
        do {
            try DiskFileAccess.deleteThumbnailDirectory()
        } catch {
            printDebug("EraserUtils: could not delete thumbnail directory: \(error)")
        }
    }

    func eraseTempDirectories() {
        for url in [URL.tempMediaDirectory,
                    URL.tempRecordingDirectory,
                    URL.tempExportDirectory,
                    CKDatabaseAdapter.assetSnapshotDirectory] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                printDebug("EraserUtils: could not remove temp directory \(url.lastPathComponent): \(error)")
            }
        }
    }

    func eraseSharedContainerImports() async {
        do {
            try await PendingImportManager.shared.cancelPendingImports()
        } catch {
            printDebug("EraserUtils: could not cancel pending imports: \(error)")
        }
        do {
            try AppGroupFileAccess.shared.clearImportDirectory()
        } catch {
            printDebug("EraserUtils: could not clear the App Group import directory: \(error)")
        }
    }

    func eraseResidualContainerFiles() {
        eraseResidualContainerFiles(roots: EraserUtils.containerRoots)
    }

    /// Root-injecting form, so a test can prove the walk against a tree it owns
    /// rather than against the container it is running inside.
    func eraseResidualContainerFiles(roots: [URL]) {
        for root in roots {
            removeContents(of: root)
        }
    }

    /// Removes every child of `directory` except the preserved names.
    ///
    /// Directories are emptied and then removed, rather than removed outright.
    /// Deleting a parent wholesale is faster but takes anything preserved inside
    /// it along — `Preferences` lives under `Library`, so a bulk delete of
    /// `Library` destroys exactly what the skip list is there to protect. The
    /// final removal is best-effort for the same reason: a directory that still
    /// holds preserved content should stay, and a system-owned one the app cannot
    /// delete has still had every file it owns taken out of it.
    private func removeContents(of directory: URL) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: []) else {
            return
        }
        for child in children where !EraserUtils.preservedNames.contains(child.lastPathComponent) {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                removeContents(of: child)
                if (try? fileManager.contentsOfDirectory(atPath: child.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: child)
                }
            } else {
                do {
                    try fileManager.removeItem(at: child)
                } catch {
                    printDebug("EraserUtils: could not remove \(child.lastPathComponent): \(error)")
                }
            }
        }
    }

    func eraseKeychain() {
        keyManager.clearKeychainData(scope: .accountWide)
        KeychainPasscodeAttemptStore().clear()
    }

    func eraseUserDefaults() {
        UserDefaultUtils.removeAll(setTombstone: true)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaultUtils.blockWritesForErase()
        UserDefaultUtils.flushPendingWrites()
    }

    func recordPendingCloudWipe() {
        UserDefaultUtils.set(true, forKey: .pendingCloudDataWipe)
        UserDefaultUtils.flushPendingWrites()
    }
}

/// Outcome of an erase. `cloudKitDeletionFailed` is true only when an `.allData`
/// wipe could not remove the user's CloudKit data (offline, transient error) AND
/// the user could actually have data there — the local wipe still completed, so
/// the caller should warn that iCloud data may remain rather than report a clean
/// reset. A pending-wipe marker is persisted in that case and retried on launch.
public struct ErasureResult {
    public let cloudKitDeletionFailed: Bool

    public init(cloudKitDeletionFailed: Bool) {
        self.cloudKitDeletionFailed = cloudKitDeletionFailed
    }
}

public struct EraserUtils {

    /// Every directory tree this app can write to.
    ///
    /// The home container covers `Documents`, `Library` and `tmp`; the App Group
    /// container is separate and is where the Share Extension hands media over;
    /// the ubiquity container holds legacy iCloud Drive albums.
    public static var containerRoots: [URL] {
        var roots = [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)]
        if let group = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: UserDefaultUtils.appGroup) {
            roots.append(group)
        }
        if let ubiquity = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            roots.append(ubiquity)
        }
        return roots
    }

    /// Names left untouched inside a container root.
    ///
    /// `Preferences` belongs to `cfprefsd`, which owns the plists and rewrites
    /// them from memory — deleting the files underneath it produces the
    /// "Couldn't read values in CFPrefsPlistSource" breakage rather than a clean
    /// wipe. `eraseUserDefaults()` is how those are cleared. `SyncedPreferences`
    /// is the same arrangement for the iCloud key-value store daemon. The other
    /// two are owned by the container manager and cannot be removed by the app
    /// at all.
    public static let preservedNames: Set<String> = [
        "Preferences",
        "SyncedPreferences",
        "SystemData",
        ".com.apple.mobile_container_manager.metadata.plist"
    ]


    public var keyManager: KeyManager
    public var fileAccess: FileAccess
    public var erasureScope: ErasureScope
    private let cloudKitEraser: CloudDataErasing
    private let localEraser: LocalDataErasing
    private let localVerifier: LocalDataVerifying
    /// Steps owned by the app target, run after the media sweep and before the
    /// residual sweep, keychain and defaults wipes so nothing they write survives.
    private let appLayerSteps: [ErasureStep]

    public init(keyManager: KeyManager,
                fileAccess: FileAccess,
                erasureScope: ErasureScope,
                cloudKitEraser: CloudDataErasing = CloudKitContainer.shared,
                localEraser: LocalDataErasing? = nil,
                localVerifier: LocalDataVerifying? = nil,
                appLayerSteps: [ErasureStep] = []) {
        self.keyManager = keyManager
        self.fileAccess = fileAccess
        self.erasureScope = erasureScope
        self.cloudKitEraser = cloudKitEraser
        self.localEraser = localEraser ?? DefaultLocalDataEraser(keyManager: keyManager, fileAccess: fileAccess)
        self.localVerifier = localVerifier ?? DefaultLocalDataVerifier(keyManager: keyManager, fileAccess: fileAccess)
        self.appLayerSteps = appLayerSteps
    }

    /// Every step this scope reports, in run order: the scope's catalog with the
    /// app-layer steps inserted into their section. Rendered by the progress
    /// screen before the run starts.
    public var stepDescriptors: [ErasureStepDescriptor] {
        let catalog = ErasureStepDescriptor.catalog(for: erasureScope)
        let appSectionIndex = ErasureStepSection.allCases.firstIndex(of: .app)!
        let before = catalog.filter { ErasureStepSection.allCases.firstIndex(of: $0.section)! < appSectionIndex }
        let after = catalog.filter { ErasureStepSection.allCases.firstIndex(of: $0.section)! > appSectionIndex }
        return before + appLayerSteps.filter { erasureScope.includes($0.descriptor.tier) }.map(\.descriptor) + after
    }

    @discardableResult
    public func erase() async throws -> ErasureResult {
        let report = await erase(progress: { _ in })
        return ErasureResult(cloudKitDeletionFailed: report.cloudKitDeletionFailed)
    }

    /// Runs `stepDescriptors` in order and reports each through `progress` twice:
    /// `.running`, then the terminal outcome its verification decided. A failure
    /// never stops the run.
    ///
    /// `.reset` removes the keys (on this device and in iCloud), settings and
    /// key-value store, decrypted thumbnails, cleartext temp files, shared
    /// imports, migration checkpoints and app-layer state, and keeps the
    /// encrypted media, its indexes, the blob cache, the upload queue and the
    /// CloudKit zone. `.allData` adds all of those.
    ///
    /// In-flight migrations are halted FIRST so nothing keeps writing checkpoints
    /// or issuing CloudKit operations; the CloudKit checks run before the
    /// residual sweep, which removes `Library/Caches/CloudKit` and breaks every
    /// later CloudKit read; the keychain wipe runs after the media so deleting the
    /// keys orphans nothing. A `pendingCloudDataWipe` marker from an earlier run
    /// survives both scopes.
    public func erase(progress: @escaping @Sendable (ErasureStepReport) -> Void) async -> ErasureReport {
        var steps: [ErasureStepReport] = []
        var cloudKitDeletionFailed = false
        var cloudWipeOwed = false
        let scope = erasureScope

        func record(_ report: ErasureStepReport) {
            steps.append(report)
            progress(report)
        }

        /// Erase, then verify whatever the erase did. The verdict decides the
        /// outcome; an erase error is kept as evidence only.
        func perform(_ id: String,
                     erase: () async throws -> Void,
                     verify: () async -> ErasureVerdict) async {
            progress(.running(id))
            var eraseError: Error?
            do {
                try await erase()
            } catch {
                print("EraserUtils: \(id) failed: \(error)")
                eraseError = error
            }
            let verdict = await verify()
            record(.terminal(id, verdict: verdict, eraseError: eraseError))
        }

        await perform("migration.state",
                      erase: { await localEraser.eraseMigrationState() },
                      verify: { await localVerifier.verifyMigrationState() })
        await perform("sync.shutdown",
                      erase: { await localEraser.shutdownCloudKitSync() },
                      verify: { await localVerifier.verifyCloudKitSyncShutdown() })

        if scope.includes(.ciphertext) {
            progress(.running("cloud.zones"))
            do {
                try await cloudKitEraser.deleteAllCloudData()
                record(await cloudVerdict("cloud.zones", label: "iCloud zones") {
                    try await cloudKitEraser.remainingZoneNames()
                })
            } catch {
                print("EraserUtils: CloudKit deletion failed: \(error)")
                if await cloudKitEraser.mayHaveCloudKitData() {
                    cloudWipeOwed = true
                    cloudKitDeletionFailed = true
                    // The server may have committed the delete even though the client
                    // saw an error; only a re-read can say.
                    record(await cloudVerdict("cloud.zones", label: "iCloud zones", eraseError: error) {
                        try await cloudKitEraser.remainingZoneNames()
                    })
                } else {
                    record(.skipped("cloud.zones", "No iCloud account on this device"))
                }
            }

            progress(.running("cloud.subscriptions"))
            do {
                try await cloudKitEraser.deleteAllSubscriptions()
                record(await cloudVerdict("cloud.subscriptions", label: "iCloud subscriptions") {
                    try await cloudKitEraser.remainingSubscriptionIDs()
                })
            } catch {
                print("EraserUtils: CloudKit subscription deletion failed: \(error)")
                if await cloudKitEraser.mayHaveCloudKitData() {
                    cloudWipeOwed = true
                    record(.terminal("cloud.subscriptions",
                                     verdict: .fail("Could not reach iCloud", hint: .cloudUnreachable),
                                     eraseError: error))
                } else {
                    record(.skipped("cloud.subscriptions", "No iCloud account on this device"))
                }
            }

            await perform("media.activeBackend",
                          erase: { await localEraser.eraseActiveBackendMedia() },
                          verify: { await localVerifier.verifyActiveBackendMedia() })
            await perform("media.localAlbums",
                          erase: { localEraser.eraseAllLocalMediaFiles() },
                          verify: { localVerifier.verifyLocalMediaFiles() })
            await perform("media.iCloudDrive",
                          erase: { localEraser.eraseICloudDriveMedia() },
                          verify: { localVerifier.verifyICloudDriveMedia() })
            await perform("media.indexes",
                          erase: { localEraser.eraseMediaIndexes() },
                          verify: { localVerifier.verifyMediaIndexes() })
            await perform("media.blobCache",
                          erase: { await localEraser.eraseBlobCache() },
                          verify: { localVerifier.verifyBlobCache() })
        }

        await perform("media.thumbnails",
                      erase: { localEraser.eraseThumbnails() },
                      verify: { localVerifier.verifyThumbnails() })
        await perform("media.temp",
                      erase: { localEraser.eraseTempDirectories() },
                      verify: { localVerifier.verifyTempDirectories() })
        await perform("media.sharedImports",
                      erase: { await localEraser.eraseSharedContainerImports() },
                      verify: { localVerifier.verifySharedContainerImports() })

        for step in appLayerSteps where scope.includes(step.descriptor.tier) {
            await perform(step.descriptor.id, erase: step.erase, verify: step.verify)
        }

        if scope.includes(.ciphertext) {
            await perform("sweep.residual",
                          erase: { localEraser.eraseResidualContainerFiles() },
                          verify: { localVerifier.verifyResidualContainerFiles() })
        }
        await perform("keys.keychain",
                      erase: { localEraser.eraseKeychain() },
                      verify: { localVerifier.verifyKeychain() })
        await perform("settings.defaults",
                      erase: {
                          localEraser.eraseUserDefaults()
                          if cloudWipeOwed {
                              // After the defaults wipe, so the marker survives it.
                              localEraser.recordPendingCloudWipe()
                          }
                      },
                      verify: { localVerifier.verifyUserDefaults() })

        await perform("final.verify",
                      erase: {},
                      verify: { await localVerifier.verifyDeviceClean(scope: scope) })

        let report = ErasureReport(descriptors: stepDescriptors,
                                   steps: steps,
                                   cloudKitDeletionFailed: cloudKitDeletionFailed,
                                   scope: scope)
        print(report.fullText)
        return report
    }

    /// Retries a cloud wipe an earlier erase could not finish. The marker is only
    /// armed when the device may have CloudKit data and is cleared when onboarding
    /// completes, so this never deletes data created after the erase.
    /// - Returns: whether a retry was attempted.
    @discardableResult
    public static func retryPendingCloudWipe(using cloudKitEraser: CloudDataErasing = CloudKitContainer.shared) async -> Bool {
        guard UserDefaultUtils.bool(forKey: .pendingCloudDataWipe) else { return false }
        do {
            try await cloudKitEraser.deleteAllCloudData()
            UserDefaultUtils.set(nil, forKey: .pendingCloudDataWipe)
        } catch {
            print("EraserUtils: pending cloud wipe retry failed: \(error)")
        }
        return true
    }

    /// Re-reads a cloud surface. A read that itself fails means iCloud is
    /// unreachable, which is a failure with a retry hint rather than a pass.
    private func cloudVerdict(_ id: String,
                              label: String,
                              eraseError: Error? = nil,
                              remaining: () async throws -> [String]) async -> ErasureStepReport {
        do {
            let names = try await remaining()
            return .terminal(id,
                             verdict: .residue(label, names: names, hint: .cloudUnreachable),
                             eraseError: eraseError)
        } catch {
            return .terminal(id,
                             verdict: .fail("Could not reach iCloud", detail: "\(error)", hint: .cloudUnreachable),
                             eraseError: eraseError)
        }
    }
}
