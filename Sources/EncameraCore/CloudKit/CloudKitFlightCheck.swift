//
//  CloudKitFlightCheck.swift
//  EncameraCore
//
//  Manual, end-to-end smoke test of the CloudKit storage plane. Runs the *real*
//  app code paths (account gating, zone bootstrap, push subscription, album
//  creation, encrypt + upload, delta sync, cold-cache server download + decrypt,
//  thumbnail fetch, delete + tombstone) with dummy data and the existing keychain
//  key, so a human can see exactly where iCloud albums break.
//
//  Drives the `ICloudFlightCheckView` workbench (behind the `iCloudFlightCheck`
//  feature toggle). Steps run in order and HALT on the first failure; each step
//  reports a readable message plus raw detail, and logs context via printDebug.
//
//  Note on the download steps: a normal `loadMedia` is served from the local cache
//  the upload just wrote, so it does NOT prove the blob is on the server. The
//  download/thumbnail steps deliberately EVICT the cache first, forcing a true
//  fetch from CloudKit. A successful run leaves the (empty) FlightCheck album for
//  inspection — the final delete step removes its uploaded record — while a halted
//  run tears down both; `removeTestAlbums` clears accumulated leftovers.
//

import Foundation
import CloudKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Step model

/// The lifecycle state of a single flight-check step, rendered by the workbench.
public enum FlightCheckStepStatus: Equatable {
    case pending
    case running
    case passed(detail: String?)
    case failed(message: String, detail: String?)
}

/// A named step in the flight-check sequence.
public struct FlightCheckStep: Identifiable, Equatable {
    public let id: Int
    public let title: String
}

// MARK: - Typed failures

/// Failures specific to the flight check (CloudKit errors are translated via
/// `mapCKError`). Each carries a concise user-facing `message` and a verbose
/// `detail` for the expandable disclosure / logs.
public enum FlightCheckError: Error {
    case entitlement(container: String, underlying: Error)
    case account(status: CKAccountStatus)
    case zoneMissing
    case noKey
    case uploadReturnedNil
    case notListed(id: String, found: Int)
    case emptyDownload
    case byteMismatch(expected: Int, got: Int)
    case emptyThumbnail
    case stillListedAfterDelete(id: String)
    case imageEncodingFailed
    case internalState(String)

    var message: String {
        switch self {
        case .entitlement(let container, _):
            return "CloudKit entitlement not configured for \(container)"
        case .account(let status):
            return "iCloud account not available (\(CloudKitFlightCheck.describe(status)))"
        case .zoneMissing:
            return "Custom zone could not be created on the server"
        case .noKey:
            return "No encryption key — set up your key first"
        case .uploadReturnedNil:
            return "Upload returned no record"
        case .notListed:
            return "Uploaded record did not appear in the synced index"
        case .emptyDownload:
            return "Server download was empty"
        case .byteMismatch:
            return "Round-trip bytes did not match the original"
        case .emptyThumbnail:
            return "Thumbnail fetched from the server was empty"
        case .stillListedAfterDelete:
            return "Record was still in the index after delete"
        case .imageEncodingFailed:
            return "Could not build the dummy test image"
        case .internalState(let what):
            return "Internal flight-check state error: \(what)"
        }
    }

    var detail: String {
        switch self {
        case .entitlement(let container, let underlying):
            return "Verify the app's entitlement includes the CloudKit service under "
                + "com.apple.developer.icloud-services and that "
                + "com.apple.developer.icloud-container-identifiers contains \(container). "
                + "Underlying: \(String(reflecting: underlying))"
        case .account(let status):
            return "CKAccountStatus = \(CloudKitFlightCheck.describe(status)) (raw \(status.rawValue)). "
                + "Sign in to iCloud in Settings and ensure iCloud Drive is enabled."
        case .zoneMissing:
            return "Even after resetting the zone-created flag and calling ensureZoneExists(), "
                + "\(CloudKitSchema.zoneName) is not present in \(CloudKitSchema.containerID)'s private DB. "
                + "Check the container exists in the CloudKit dashboard and that the account has CloudKit access."
        case .noKey:
            return "KeyManager.currentKey is nil. The flight check encrypts with the existing keychain key; create or unlock a key, then retry."
        case .uploadReturnedNil:
            return "CloudKitFileAccess.save returned nil for the dummy photo — the CloudKit save path produced no EncryptedMedia."
        case .notListed(let id, let found):
            return "After reconcile(), enumerate() returned \(found) item(s), none matching record id \(id). The blob may have written but the delta sync / index did not surface it."
        case .emptyDownload:
            return "After evicting the local cache, loadMedia() pulled the blob from CloudKit but produced no readable bytes — the asset may not be on the server."
        case .byteMismatch(let expected, let got):
            return "Downloaded \(got) bytes from the server but expected \(expected). The blob round-tripped but did not decrypt to the original — possible encryption-key or asset-corruption issue."
        case .emptyThumbnail:
            return "After evicting the local thumbnail, loadMediaPreview() fetched the eager encThumbnail asset from CloudKit but it decoded to no data — the thumbnail asset may not have uploaded."
        case .stillListedAfterDelete(let id):
            return "After delete + reconcile, record id \(id) is still present in the synced index — the tombstone did not propagate."
        case .imageEncodingFailed:
            return "UIGraphicsImageRenderer / jpegData produced no data for the synthetic test image."
        case .internalState(let what):
            return what
        }
    }
}

// MARK: - Engine

/// Runs the CloudKit flight-check sequence. Construct once per run; not Sendable
/// (the run is sequential and single-flight from the workbench view model).
public final class CloudKitFlightCheck: DebugPrintable {

    /// The ordered checks. Indices are stable and used as `FlightCheckStepStatus`
    /// keys by the view model.
    public static let steps: [FlightCheckStep] = [
        .init(id: 0,  title: "CloudKit entitlement configured"),
        .init(id: 1,  title: "iCloud account available"),
        .init(id: 2,  title: "CloudKit container reachable"),
        .init(id: 3,  title: "Custom zone ready"),
        .init(id: 4,  title: "Push subscription registered"),
        .init(id: 5,  title: "Encryption key available"),
        .init(id: 6,  title: "Create test CloudKit album"),
        .init(id: 7,  title: "Encrypt & upload test photo"),
        .init(id: 8,  title: "Sync & list uploaded item"),
        .init(id: 9,  title: "Download blob from server (cold cache)"),
        .init(id: 10, title: "Thumbnail from server (cold cache)"),
        .init(id: 11, title: "Delete & tombstone propagation"),
    ]

    private let keyManager: KeyManager
    private let albumManager: AlbumManaging
    private let container: CloudKitContainer

    // Carried across steps so the upload/list/download/delete steps reuse the album.
    private var testAlbum: Album?
    private var cloud: CloudKitFileAccess?
    private var savedMedia: InteractableMedia<EncryptedMedia>?
    private var originalJPEG: Data?

    public init(keyManager: KeyManager,
                albumManager: AlbumManaging,
                container: CloudKitContainer = .shared) {
        self.keyManager = keyManager
        self.albumManager = albumManager
        self.container = container
    }

    /// Runs every step in order, reporting status transitions through `onUpdate`.
    /// Stops at the first failure (later steps remain `.pending`) and tears down
    /// its own test data — only a fully successful run leaves the (empty) test
    /// album behind for inspection.
    public func run(onUpdate: @MainActor @escaping (_ index: Int, _ status: FlightCheckStepStatus) -> Void) async {
        printDebug("Starting iCloud Flight Check — container=\(CloudKitSchema.containerID), zone=\(CloudKitSchema.zoneName)")
        for step in Self.steps {
            if Task.isCancelled {
                printDebug("iCloud Flight Check cancelled before step \(step.id) — cleaning up.")
                scheduleCleanup()
                return
            }
            await onUpdate(step.id, .running)
            printDebug("▶︎ step \(step.id) [\(step.title)] running")
            do {
                let detail = try await runStep(step.id)
                printDebug("✓ step \(step.id) [\(step.title)] passed\(detail.map { " — \($0)" } ?? "")")
                await onUpdate(step.id, .passed(detail: detail))
            } catch {
                let (message, detail) = describe(error)
                printDebug("✗ step \(step.id) [\(step.title)] FAILED: \(message)\n    detail: \(detail)")
                await onUpdate(step.id, .failed(message: message, detail: detail))
                printDebug("Halting iCloud Flight Check at step \(step.id).")
                scheduleCleanup()
                return
            }
        }
        printDebug("iCloud Flight Check complete — all steps passed. Test album left in place for inspection: \(testAlbum?.name ?? "?")")
    }

    /// Best-effort teardown for a run that halted (failure or cancellation) before
    /// the delete step: reclaims the uploaded record — its full-size `encBlob` +
    /// `encThumbnail` CKAssets would otherwise sit orphaned in the user's private
    /// database forever, since every run uses a fresh UUID-suffixed album and no
    /// re-run ever touches them — and removes the now-useless test album. Runs
    /// detached so it still executes when the run's own task was cancelled (e.g.
    /// the workbench view was dismissed mid-run).
    private func scheduleCleanup() {
        let cloud = self.cloud
        let saved = self.savedMedia
        let album = self.testAlbum
        let albumManager = self.albumManager
        Task.detached {
            if let cloud, let saved {
                try? await cloud.delete(media: [saved])
            }
            if let album {
                albumManager.delete(album: album)
            }
        }
    }

    // MARK: Test-album housekeeping

    /// The name prefix every flight-check album uses. `removeTestAlbums` keys on it.
    public static let testAlbumNamePrefix = "FlightCheck "

    /// Deletes every album left behind by previous flight-check runs (marker,
    /// local cache, and index — see `AlbumManager.delete`). Successful runs leave
    /// their empty album for inspection, so these accumulate without this.
    /// Returns how many albums were removed.
    @discardableResult
    public static func removeTestAlbums(albumManager: AlbumManaging) -> Int {
        let testAlbums = albumManager.fetchAlbumsFromFilesystem(includingHidden: true)
            .filter { $0.name.hasPrefix(testAlbumNamePrefix) }
        for album in testAlbums {
            albumManager.delete(album: album)
        }
        return testAlbums.count
    }

    private func runStep(_ index: Int) async throws -> String? {
        switch index {
        case 0:  return try await checkEntitlement()
        case 1:  return try await checkAccount()
        case 2:  return try await checkContainerReachable()
        case 3:  return try await checkZone()
        case 4:  return try await checkSubscription()
        case 5:  return try checkKey()
        case 6:  return try checkCreateAlbum()
        case 7:  return try await checkUpload()
        case 8:  return try await checkSyncAndList()
        case 9:  return try await checkColdDownload()
        case 10: return try await checkColdThumbnail()
        case 11: return try await checkDelete()
        default: return nil
        }
    }

    // MARK: Steps

    /// There is no runtime API to read our own entitlements, so we infer the
    /// CloudKit entitlement by probing the private DB and classifying the error.
    /// Only entitlement/container-class errors fail here; a missing account or a
    /// network error is deferred to the dedicated later steps.
    private func checkEntitlement() async throws -> String? {
        do {
            _ = try await container.privateDB.allRecordZones()
            return "Container \(CloudKitSchema.containerID) accepted a private-DB request"
        } catch let ckError as CKError {
            switch ckError.code {
            case .missingEntitlement, .badContainer, .badDatabase:
                throw FlightCheckError.entitlement(container: CloudKitSchema.containerID, underlying: ckError)
            default:
                return "Entitlement present (probe returned .\(ckError.code) — handled by a later step)"
            }
        } catch {
            return "Entitlement present (probe deferred: \(error.localizedDescription))"
        }
    }

    private func checkAccount() async throws -> String? {
        let status = await container.accountStatus()
        guard status == .available else {
            throw FlightCheckError.account(status: status)
        }
        return "Account status: available"
    }

    private func checkContainerReachable() async throws -> String? {
        let zones = try await container.privateDB.allRecordZones()
        return "Reached \(CloudKitSchema.containerID) private DB (\(zones.count) zone(s))"
    }

    /// Verifies the custom zone actually exists in THIS container by fetching the
    /// zone list — never trusting the persisted "zone created" flag, which can be
    /// stale (a flag set for a previous container/account silently suppresses
    /// creation, leaving the new container with no zone). If it's missing, force a
    /// recreate and re-verify.
    private func checkZone() async throws -> String? {
        if try await zoneExistsOnServer() {
            return "Zone '\(CloudKitSchema.zoneName)' exists in \(CloudKitSchema.containerID)"
        }
        container.resetZoneCreatedFlag()
        try await container.ensureZoneExists()
        guard try await zoneExistsOnServer() else {
            throw FlightCheckError.zoneMissing
        }
        return "Zone '\(CloudKitSchema.zoneName)' created in \(CloudKitSchema.containerID)"
    }

    private func zoneExistsOnServer() async throws -> Bool {
        let zones = try await container.privateDB.allRecordZones()
        return zones.contains { $0.zoneID.zoneName == CloudKitSchema.zoneName }
    }

    /// Registers the zone push subscription — the same call the coordinator makes in
    /// `startObserving()`. Zone-level, so it needs no album.
    private func checkSubscription() async throws -> String? {
        let store = CloudKitStoreProvider.makeStore("flightcheck")
        try await store.registerZoneSubscription()
        return "Zone push subscription registered"
    }

    private func checkKey() throws -> String? {
        guard let key = keyManager.currentKey else {
            throw FlightCheckError.noKey
        }
        return "Using key '\(key.name)' (\(key.keyBytes.count) bytes)"
    }

    private func checkCreateAlbum() throws -> String? {
        // A UUID suffix guarantees a unique album name (and therefore a unique
        // name-derived storage directory / discovery marker) even across rapid
        // re-runs in the same second or leftover albums from previous runs.
        let name = "\(Self.testAlbumNamePrefix)\(Self.timestamp()) #\(String(NSUUID().uuidString.prefix(8)))"
        let album = try albumManager.create(name: name, storageOption: .cloudKit)
        testAlbum = album
        return "Created album '\(name)' (id \(album.id))"
    }

    private func checkUpload() async throws -> String? {
        guard let album = testAlbum else { throw FlightCheckError.internalState("no test album from step 6") }
        let jpeg = try Self.makeDummyJPEG()
        originalJPEG = jpeg

        let cleartext = CleartextMedia(source: jpeg, mediaType: .photo, id: NSUUID().uuidString)
        let interactable = try InteractableMedia(underlyingMedia: [cleartext])

        // Exact cloud path: CloudKitFileAccess (production wiring — shared coordinator
        // via the registry, shared blob cache) → encrypt (SecretFileHandlerV2) →
        // CloudKitMediaStore.upload (writes the encBlob + encThumbnail CKAssets).
        let cloud = await CloudKitFileAccess(album: album, albumManager: albumManager)
        self.cloud = cloud
        await cloud.start()

        var metadata = EncryptedFileMetadata()
        metadata.captureDate = Date()
        metadata.encryptionDate = Date()
        metadata.originalMediaType = "photo"
        metadata.originalExtension = "jpg"
        metadata.originalFileSize = UInt64(jpeg.count)

        guard let saved = try await cloud.save(media: interactable, metadata: metadata, progress: { _ in }) else {
            throw FlightCheckError.uploadReturnedNil
        }
        savedMedia = saved
        return "Uploaded record id \(saved.id) — \(jpeg.count) bytes encrypted"
    }

    private func checkSyncAndList() async throws -> String? {
        guard let cloud, let saved = savedMedia else {
            throw FlightCheckError.internalState("no upload to verify from step 7")
        }
        _ = await cloud.reconcile()
        let listed = await cloud.enumerate()
        guard listed.contains(where: { $0.id == saved.id }) else {
            throw FlightCheckError.notListed(id: saved.id, found: listed.count)
        }
        return "Synced index lists \(listed.count) item(s), including the test record"
    }

    /// Evicts the locally-cached ciphertext, then downloads + decrypts from CloudKit.
    /// This is the real proof the blob is durable server-side (a plain `loadMedia`
    /// would be served from the cache the upload just wrote). A freshly-created record
    /// can briefly read back as `notFound` (CloudKit asset/record propagation), so the
    /// fetch is retried with backoff before it's treated as a genuine failure.
    private func checkColdDownload() async throws -> String? {
        guard let cloud, let saved = savedMedia, let original = originalJPEG else {
            throw FlightCheckError.internalState("no upload to download from step 7")
        }
        try await cloud.evictCachedBlob(for: saved.id, type: .photo)
        let decrypted = try await retrying("cold blob download") {
            try await cloud.loadMedia(media: saved, progress: { _ in })
        }
        guard let item = decrypted.underlyingMedia.first else { throw FlightCheckError.emptyDownload }
        let bytes = item.data ?? item.url.flatMap { try? Data(contentsOf: $0) }
        guard let downloaded = bytes, !downloaded.isEmpty else { throw FlightCheckError.emptyDownload }
        guard downloaded == original else {
            throw FlightCheckError.byteMismatch(expected: original.count, got: downloaded.count)
        }
        return "Downloaded \(downloaded.count) bytes from CloudKit — match the original"
    }

    /// Evicts the local thumbnail, then fetches + decrypts the eager `encThumbnail`
    /// asset from CloudKit (the gallery-grid path). Retried with backoff for the same
    /// propagation reason as the blob download.
    private func checkColdThumbnail() async throws -> String? {
        guard let cloud, let saved = savedMedia else {
            throw FlightCheckError.internalState("no upload to preview from step 7")
        }
        await cloud.evictThumbnail(for: saved.id)
        let preview = try await retrying("cold thumbnail fetch") {
            try await cloud.loadMediaPreview(for: saved)
        }
        guard let bytes = preview.thumbnailMedia.data, !bytes.isEmpty else {
            throw FlightCheckError.emptyThumbnail
        }
        return "Fetched + decoded \(bytes.count)-byte thumbnail from CloudKit"
    }

    /// Retries `op` on transient failures (e.g. a just-created record/asset that hasn't
    /// propagated yet) with a fixed backoff. Re-throws the last error if all attempts
    /// fail. Logs each attempt so a persistent failure is distinguishable from a race.
    private func retrying<T>(_ label: String,
                             attempts: Int = 6,
                             delaySeconds: Double = 1.5,
                             _ op: () async throws -> T) async throws -> T {
        var lastError: Error = FlightCheckError.internalState("no attempts made for \(label)")
        for attempt in 1...attempts {
            do {
                let value = try await op()
                if attempt > 1 { printDebug("\(label): succeeded on attempt \(attempt)/\(attempts)") }
                return value
            } catch {
                lastError = error
                printDebug("\(label): attempt \(attempt)/\(attempts) failed — \(mapCKError(error).description)")
                if attempt < attempts {
                    // Propagate cancellation (Task.sleep throws CancellationError)
                    // instead of swallowing it — a dismissed workbench must be able
                    // to stop the retry loop, not just wait it out.
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
        }
        throw lastError
    }

    /// Deletes the uploaded record (tombstone + purge) and verifies it disappears
    /// from the synced index. Leaves the (now empty) album for inspection.
    private func checkDelete() async throws -> String? {
        guard let cloud, let saved = savedMedia else {
            throw FlightCheckError.internalState("no upload to delete from step 7")
        }
        try await cloud.delete(media: [saved])
        _ = await cloud.reconcile()
        let listed = await cloud.enumerate()
        guard !listed.contains(where: { $0.id == saved.id }) else {
            throw FlightCheckError.stillListedAfterDelete(id: saved.id)
        }
        return "Record tombstoned and removed from the synced index"
    }

    // MARK: Helpers

    /// Splits an error into a concise message and verbose detail for the UI/logs.
    private func describe(_ error: Error) -> (message: String, detail: String) {
        if let fcError = error as? FlightCheckError {
            return (fcError.message, fcError.detail)
        }
        if let ckError = error as? CKError {
            let mapped = mapCKError(ckError)
            let detail = "CKError .\(ckError.code) (code \(ckError.code.rawValue))\nuserInfo: \(ckError.errorUserInfo)"
            return (mapped.description, detail)
        }
        let mapped = mapCKError(error)
        return (mapped.description, String(reflecting: error))
    }

    static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "no account"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "could not determine"
        case .temporarilyUnavailable: return "temporarily unavailable"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    /// A small solid-color JPEG, used as the dummy photo payload.
    private static func makeDummyJPEG() throws -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw FlightCheckError.imageEncodingFailed
        }
        return data
        #else
        throw FlightCheckError.imageEncodingFailed
        #endif
    }
}
