import Combine
import XCTest
@testable import EncameraCore

/// Collects values from `@Sendable` closures.
private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Adding the key a locked album needs, gated on the album's recorded
/// fingerprint and proved against its encrypted name.
final class LockedAlbumKeyEntryTests: XCTestCase {

    private var tempDirectory: URL!
    private let deviceKey = PrivateKey(keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))

    private let foreignPhrase = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
    private let wrongPhrase = ["zulu", "yankee", "xray", "whiskey", "victor", "uniform"]

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LockedAlbumKeyEntryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        for url in createdAlbumDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        createdAlbumDirectories = []
    }

    /// Album directories created in the app's real local albums directory, which
    /// `AlbumManager` reads with no injection point.
    private var createdAlbumDirectories: [URL] = []

    /// A device holding only its own key, and an album whose name is encrypted
    /// under the key `foreignPhrase` derives.
    private func makeScenario(requiredKey: (PrivateKey) -> RequiredKeyIdentity?) throws -> (manager: DemoKeyManager, foreignKey: PrivateKey, placeholder: LockedAlbumPlaceholder) {
        let manager = DemoKeyManager(keys: [deviceKey])
        manager.currentKey = deviceKey
        let foreignKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        let album = Album(name: "Holiday", storageOption: .cloudKit, creationDate: Date(), key: foreignKey)
        let placeholder = LockedAlbumPlaceholder(encryptedDirectoryName: album.encryptedPathComponent,
                                                 storageOption: .cloudKit,
                                                 creationDate: album.creationDate,
                                                 requiredKey: requiredKey(foreignKey))
        return (manager, foreignKey, placeholder)
    }

    private func addKey(_ phrase: [String],
                        manager: DemoKeyManager,
                        placeholder: LockedAlbumPlaceholder) async throws -> PrivateKey {
        try await MissingKeyEntry(keyManager: manager)
            .addKey(phraseComponents: phrase,
                    requiredKey: placeholder.requiredKey,
                    verify: { placeholder.proveKey($0) })
    }

    // MARK: - Fingerprint known

    func testMatchingFingerprintAddsKeyWithoutReplacingCurrent() async throws {
        let scenario = try makeScenario { .fingerprint($0.keyFingerprint) }

        let added = try await addKey(foreignPhrase, manager: scenario.manager, placeholder: scenario.placeholder)

        XCTAssertEqual(added.keyFingerprint, scenario.foreignKey.keyFingerprint)
        let labels = Set(try scenario.manager.storedKeys().map(\.keyFingerprint))
        XCTAssertEqual(labels, [deviceKey.keyFingerprint, scenario.foreignKey.keyFingerprint])
        XCTAssertEqual(scenario.manager.currentKey?.keyBytes, deviceKey.keyBytes, "an added key must never become current")
    }

    func testMismatchedFingerprintIsRejectedAndSavesNothing() async throws {
        let scenario = try makeScenario { .fingerprint($0.keyFingerprint) }

        do {
            _ = try await addKey(wrongPhrase, manager: scenario.manager, placeholder: scenario.placeholder)
            XCTFail("a phrase for another key must be rejected")
        } catch let error as MissingKeyEntryError {
            guard case .wrongKey(_, let required) = error else {
                return XCTFail("expected .wrongKey, got \(error)")
            }
            XCTAssertEqual(required, scenario.placeholder.requiredKey)
            XCTAssertTrue(error.displayDescription.contains(scenario.placeholder.requiredKey!.displayLabel),
                          "the rejection must name the key the album needs")
        }
        XCTAssertEqual(try scenario.manager.storedKeys().count, 1)
    }

    /// The CloudKit `keyFingerprint` is not covered by the AEAD. A phrase that
    /// matches a stale fingerprint but does not open the album name must not be
    /// saved.
    func testMatchingFingerprintThatDoesNotOpenTheNameIsRejected() async throws {
        let scenario = try makeScenario { _ in nil }
        let wrongKey = try PrivateKey(passphrase: KeyPassphrase(words: wrongPhrase))
        let stale = LockedAlbumPlaceholder(encryptedDirectoryName: scenario.placeholder.encryptedDirectoryName,
                                           storageOption: .cloudKit,
                                           creationDate: scenario.placeholder.creationDate,
                                           requiredKey: .fingerprint(wrongKey.keyFingerprint))

        do {
            _ = try await addKey(wrongPhrase, manager: scenario.manager, placeholder: stale)
            XCTFail("a key that does not open the album name must be rejected")
        } catch let error as MissingKeyEntryError {
            guard case .wrongKey(_, let required) = error else {
                return XCTFail("expected .wrongKey, got \(error)")
            }
            XCTAssertNil(required)
        }
        XCTAssertEqual(try scenario.manager.storedKeys().count, 1)
    }

    // MARK: - Fingerprint unknown

    func testUnknownFingerprintAcceptsTheKeyThatOpensTheName() async throws {
        let scenario = try makeScenario { _ in nil }

        _ = try await addKey(foreignPhrase, manager: scenario.manager, placeholder: scenario.placeholder)

        XCTAssertEqual(try scenario.manager.storedKeys().count, 2)
        XCTAssertEqual(scenario.manager.currentKey?.keyBytes, deviceKey.keyBytes)
    }

    func testUnknownFingerprintRejectsAKeyThatDoesNotOpenTheName() async throws {
        let scenario = try makeScenario { _ in nil }

        do {
            _ = try await addKey(wrongPhrase, manager: scenario.manager, placeholder: scenario.placeholder)
            XCTFail("the album-name proof is the gate when no fingerprint is known")
        } catch let error as MissingKeyEntryError {
            guard case .wrongKey = error else {
                return XCTFail("expected .wrongKey, got \(error)")
            }
        }
        XCTAssertEqual(try scenario.manager.storedKeys().count, 1)
    }

    // MARK: - Never overwrite

    func testKeyAlreadyHeldIsRefusedAndLeftUntouched() async throws {
        let scenario = try makeScenario { .fingerprint($0.keyFingerprint) }
        try scenario.manager.save(key: scenario.foreignKey, setNewKeyToCurrent: false)
        let before = try scenario.manager.storedKeys()

        do {
            _ = try await addKey(foreignPhrase, manager: scenario.manager, placeholder: scenario.placeholder)
            XCTFail("expected .alreadyHeld")
        } catch let error as MissingKeyEntryError {
            XCTAssertEqual(error, .alreadyHeld)
        }

        let after = try scenario.manager.storedKeys()
        XCTAssertEqual(after.map(\.keyFingerprint), before.map(\.keyFingerprint))
        XCTAssertEqual(after.map(\.uuid), before.map(\.uuid), "the stored item must not be rewritten")
    }

    // MARK: - Proof

    func testNameProofDistinguishesKeys() throws {
        let scenario = try makeScenario { _ in nil }

        XCTAssertEqual(scenario.placeholder.proveKey(scenario.foreignKey), .proved)
        XCTAssertEqual(scenario.placeholder.proveKey(deviceKey), .disproved)
    }

    // MARK: - RequiredKeyIdentity

    func testFingerprintAndStampPrefixOfTheSameKeyShareALabel() throws {
        let key = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))

        XCTAssertEqual(RequiredKeyIdentity.fingerprint(key.keyFingerprint).displayLabel,
                       RequiredKeyIdentity.stampPrefix(key.stampPrefix).displayLabel)
        XCTAssertTrue(RequiredKeyIdentity.fingerprint(key.keyFingerprint).matches(key))
        XCTAssertTrue(RequiredKeyIdentity.stampPrefix(key.stampPrefix).matches(key))
    }

    func testMalformedStoredFingerprintIsTreatedAsUnknown() {
        XCTAssertNil(RequiredKeyIdentity(fingerprintHex: nil))
        XCTAssertNil(RequiredKeyIdentity(fingerprintHex: "encamera_default_key"))
        XCTAssertNil(RequiredKeyIdentity(fingerprintHex: String(repeating: "A", count: 32)))
        XCTAssertEqual(RequiredKeyIdentity(fingerprintHex: String(repeating: "a", count: 32)),
                       .fingerprint(String(repeating: "a", count: 32)))
    }

    // MARK: - LockedAlbumKeyProbe

    private func writeMedia(named name: String, in directory: URL, key: PrivateKey?, stamp: Bool) async throws {
        let signingKey = key ?? deviceKey
        let cleartext = CleartextMedia(source: Data(repeating: 7, count: 30000), mediaType: .photo, id: name)
        let url = directory.appendingPathComponent("\(name).\(MediaType.photo.encryptedFileExtension)")
        _ = try await SecretFileHandlerV2(keyBytes: signingKey.keyBytes, source: cleartext, targetURL: url)
            .encryptWithMetadata(EncryptedFileMetadata())
        if stamp {
            KeyStampSlot.writeStamp(signingKey.stampPrefix, url: url)
        }
    }

    func testProbeReadsTheStampTheAlbumsMediaAgreesOn() async throws {
        let key = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        try await writeMedia(named: "a", in: tempDirectory, key: key, stamp: true)
        try await writeMedia(named: "b", in: tempDirectory, key: key, stamp: false)

        XCTAssertEqual(LockedAlbumKeyProbe.requiredKey(albumDirectory: tempDirectory), .stampPrefix(key.stampPrefix))
    }

    func testProbeReportsUnknownForUnstampedMedia() async throws {
        try await writeMedia(named: "a", in: tempDirectory, key: nil, stamp: false)

        XCTAssertNil(LockedAlbumKeyProbe.requiredKey(albumDirectory: tempDirectory))
    }

    func testProbeReportsUnknownWhenStampsDisagree() async throws {
        let key = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        try await writeMedia(named: "a", in: tempDirectory, key: key, stamp: true)
        try await writeMedia(named: "b", in: tempDirectory, key: nil, stamp: true)

        XCTAssertNil(LockedAlbumKeyProbe.requiredKey(albumDirectory: tempDirectory))
    }

    // MARK: - Albums whose name key is missing

    /// A local album directory whose name is encrypted under `nameKey`, as a
    /// device that held `nameKey` when it created the album left it.
    private func seedLocalAlbumDirectory(nameKey: PrivateKey) throws -> URL {
        let album = Album(name: "LAKE-\(UUID().uuidString.prefix(8))", storageOption: .local, creationDate: Date(), key: nameKey)
        let url = LocalStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        createdAlbumDirectories.append(url)
        return url
    }

    private func albumManager(holding keys: [PrivateKey], current: PrivateKey) -> AlbumManager {
        let keyManager = DemoKeyManager(keys: keys)
        keyManager.currentKey = current
        return AlbumManager(keyManager: keyManager)
    }

    /// Lists albums the way the grid does, waits for the content probes the
    /// first listing starts, and lists again.
    private func listAfterProbing(_ manager: AlbumManager) async -> [Album] {
        _ = manager.fetchAlbumsFromSources(includingHidden: true)
        await manager.waitForLockedContentProbes()
        return manager.fetchAlbumsFromSources(includingHidden: true)
    }

    private func diskAccess(for album: Album, keys: [PrivateKey], current: PrivateKey) async -> DiskFileAccess {
        let keyManager = DemoKeyManager(keys: keys)
        keyManager.currentKey = current
        let demoManager = DemoAlbumManager()
        demoManager.keyManager = keyManager
        let access = DiskFileAccess()
        await access.configure(for: album, albumManager: demoManager)
        return access
    }

    private func encryptedMedia(_ name: String, in directory: URL) -> EncryptedMedia {
        EncryptedMedia(source: directory.appendingPathComponent("\(name).\(MediaType.photo.encryptedFileExtension)"),
                       mediaType: .photo,
                       id: name)
    }

    /// Up to 2.9.x a directory album opened under the current key whatever key
    /// named it, so a device whose key was K2 imported K2 media into an album named
    /// under K1. With K1 absent, that album must open under K2 and keep its directory.
    func testAlbumNamedUnderMissingKeyWithCurrentKeyContentsIsReachable() async throws {
        let nameKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        let directory = try seedLocalAlbumDirectory(nameKey: nameKey)
        try await writeMedia(named: "one", in: directory, key: deviceKey, stamp: false)
        try await writeMedia(named: "two", in: directory, key: deviceKey, stamp: false)
        let manager = albumManager(holding: [deviceKey], current: deviceKey)

        let albums = await listAfterProbing(manager)

        let album = try XCTUnwrap(albums.first { $0.encryptedPathComponent == directory.lastPathComponent },
                                  "an album whose media the current key opens must be listed")
        XCTAssertEqual(album.key, deviceKey)
        XCTAssertEqual(album.storageURL.standardizedFileURL, directory.standardizedFileURL, "nothing is renamed on disk")
        XCTAssertTrue(album.isNameUnavailable)
        XCTAssertEqual(album.displayName, L10n.MissingKey.albumNameUnavailable)
        XCTAssertFalse(manager.lockedAlbums.contains { $0.encryptedDirectoryName == directory.lastPathComponent })

        let access = await diskAccess(for: album, keys: [deviceKey], current: deviceKey)
        let decrypted = try await access.loadMediaInMemory(media: encryptedMedia("one", in: directory), progress: { _ in })
        guard case .data(let data) = decrypted.source else {
            return XCTFail("expected in-memory data")
        }
        XCTAssertEqual(data, Data(repeating: 7, count: 30000))
    }

    /// K2 and K1 media in one album: the album is listed under K2, and the K1
    /// media is reported as needing a missing key, which the grid shows as a
    /// locked tile.
    func testAlbumWithMixedKeyContentsIsSurfacedPartially() async throws {
        let nameKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        let directory = try seedLocalAlbumDirectory(nameKey: nameKey)
        try await writeMedia(named: "mine", in: directory, key: deviceKey, stamp: false)
        try await writeMedia(named: "theirs", in: directory, key: nameKey, stamp: false)
        let manager = albumManager(holding: [deviceKey], current: deviceKey)

        let albums = await listAfterProbing(manager)

        let album = try XCTUnwrap(albums.first { $0.encryptedPathComponent == directory.lastPathComponent })
        XCTAssertEqual(album.key, deviceKey)

        let outcome = await LockedAlbumContentProbe.probe(albumDirectory: directory,
                                                          keyManager: manager.keyManager,
                                                          storedKeys: [deviceKey])
        XCTAssertEqual(outcome, .readable(key: deviceKey,
                                          lockedFileNames: ["theirs.\(MediaType.photo.encryptedFileExtension)"]))

        let access = await diskAccess(for: album, keys: [deviceKey], current: deviceKey)
        _ = try await access.loadMediaInMemory(media: encryptedMedia("mine", in: directory), progress: { _ in })
        do {
            _ = try await access.loadMediaInMemory(media: encryptedMedia("theirs", in: directory), progress: { _ in })
            XCTFail("media under the absent key must not open")
        } catch FileAccessError.missingKeyForMedia {
            // The grid renders this as a missing-key tile.
        }
    }

    func testAlbumWithNoReadableContentsStaysLocked() async throws {
        let nameKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        let directory = try seedLocalAlbumDirectory(nameKey: nameKey)
        try await writeMedia(named: "a", in: directory, key: nameKey, stamp: false)
        try await writeMedia(named: "b", in: directory, key: nameKey, stamp: false)
        let manager = albumManager(holding: [deviceKey], current: deviceKey)

        let albums = await listAfterProbing(manager)

        XCTAssertFalse(albums.contains { $0.encryptedPathComponent == directory.lastPathComponent })
        let placeholder = try XCTUnwrap(manager.lockedAlbums.first { $0.encryptedDirectoryName == directory.lastPathComponent })
        XCTAssertTrue(placeholder.contentsUnreadable, "the placeholder must say no key on this device opens its contents")
    }

    func testContentProbeIsBoundedPerAlbum() async throws {
        let nameKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        let fileCount = LockedAlbumContentProbe.maxFilesSampled * 3
        for index in 0..<fileCount {
            try await writeMedia(named: "file-\(index)", in: tempDirectory, key: nameKey, stamp: false)
        }
        let keyManager = DemoKeyManager(keys: [deviceKey])
        keyManager.currentKey = deviceKey
        var probed: [URL] = []

        let outcome = await LockedAlbumContentProbe.probe(albumDirectory: tempDirectory,
                                                          keyManager: keyManager,
                                                          storedKeys: [deviceKey],
                                                          onFileProbed: { probed.append($0) })

        XCTAssertEqual(outcome, .noneOpened)
        XCTAssertEqual(probed.count, LockedAlbumContentProbe.maxFilesSampled)
        XCTAssertEqual(Set(probed).count, probed.count)
    }

    /// A probe's result is reused for the session, and a key added later
    /// invalidates it.
    func testContentProbeResultIsCachedPerKeyLibrary() async throws {
        let cache = LockedAlbumContentProbeCache()
        XCTAssertNil(cache.outcome(for: tempDirectory, keyLibrary: ["a"]))

        _ = await cache.probe(directory: tempDirectory, keyLibrary: ["a"], run: {
            LockedAlbumContentProbeCache.Result(outcome: .noneOpened, requiredKey: nil)
        }).value

        XCTAssertEqual(cache.outcome(for: tempDirectory, keyLibrary: ["a"]), .noneOpened)
        XCTAssertNil(cache.outcome(for: tempDirectory, keyLibrary: ["a", "b"]))
    }

    // MARK: - Listing never reads media

    func testListingOpensNoMediaFileForLockedAlbum() async throws {
        let nameKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        let manager = albumManager(holding: [deviceKey], current: deviceKey)
        let directory = try seedLocalAlbumDirectory(nameKey: nameKey)
        try await writeMedia(named: "a", in: directory, key: nameKey, stamp: true)
        try await writeMedia(named: "b", in: directory, key: nameKey, stamp: true)
        let opened = Recorder<URL>()

        LockedAlbumProbeFiles.$onMediaFileOpened.withValue({ opened.append($0) }) {
            _ = manager.fetchAlbumsFromSources(includingHidden: true)
        }
        await manager.waitForLockedContentProbes()
        LockedAlbumProbeFiles.$onMediaFileOpened.withValue({ opened.append($0) }) {
            _ = manager.fetchAlbumsFromSources(includingHidden: true)
        }

        XCTAssertEqual(opened.values, [], "a listing must read no media file, cold or cached")
        XCTAssertTrue(manager.lockedAlbums.contains { $0.encryptedDirectoryName == directory.lastPathComponent })
    }

    func testLockedLocalAlbumRequiredKeyComesFromTheProbeCache() async throws {
        let nameKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        // Created first, so its own launch listing never sees the album.
        let manager = albumManager(holding: [deviceKey], current: deviceKey)
        let directory = try seedLocalAlbumDirectory(nameKey: nameKey)
        try await writeMedia(named: "a", in: directory, key: nameKey, stamp: true)
        try await writeMedia(named: "b", in: directory, key: nameKey, stamp: true)
        let placeholder = { manager.lockedAlbums.first { $0.encryptedDirectoryName == directory.lastPathComponent } }

        _ = manager.fetchAlbumsFromSources(includingHidden: true)
        XCTAssertNotNil(placeholder())
        XCTAssertNil(placeholder()?.requiredKey, "unknown until the probe finishes")

        await manager.waitForLockedContentProbes()
        _ = manager.fetchAlbumsFromSources(includingHidden: true)

        XCTAssertEqual(placeholder()?.requiredKey, .stampPrefix(nameKey.stampPrefix))
        XCTAssertEqual(placeholder()?.contentsUnreadable, true)
    }

    /// iCloud Drive files are never stamped, so the probe does not read stamps
    /// for an iCloud Drive album even when its files carry one.
    func testLockedICloudDriveAlbumHasNoRequiredKeyAndNoStampRead() async throws {
        let nameKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        try await writeMedia(named: "a", in: tempDirectory, key: nameKey, stamp: true)
        let manager = albumManager(holding: [deviceKey], current: deviceKey)
        let keyLibrary = manager.keyLibraryIdentity(storedKeys: [deviceKey])

        let iCloud = await manager.startContentProbe(directoryURL: tempDirectory,
                                                     storageType: .icloud,
                                                     storedKeys: [deviceKey],
                                                     keyLibrary: keyLibrary).value

        XCTAssertNil(iCloud.requiredKey)
        XCTAssertNil(manager.lockedContentProbes.result(for: tempDirectory, keyLibrary: keyLibrary)?.requiredKey)
        XCTAssertEqual(iCloud.outcome, .noneOpened)

        let local = await albumManager(holding: [deviceKey], current: deviceKey)
            .startContentProbe(directoryURL: tempDirectory,
                               storageType: .local,
                               storedKeys: [deviceKey],
                               keyLibrary: keyLibrary).value
        XCTAssertEqual(local.requiredKey, .stampPrefix(nameKey.stampPrefix), "the same files read as local do name the key")
    }

    func testContentProbeSkipsFilesThatNeedDownload() async throws {
        let nameKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        try await writeMedia(named: "a", in: tempDirectory, key: deviceKey, stamp: true)
        try await writeMedia(named: "b", in: tempDirectory, key: nameKey, stamp: true)
        let keyManager = DemoKeyManager(keys: [deviceKey])
        keyManager.currentKey = deviceKey
        let opened = Recorder<URL>()
        let probed = Recorder<URL>()

        let (outcome, requiredKey) = await LockedAlbumProbeFiles.$needsDownload.withValue({ _ in true }) {
            await LockedAlbumProbeFiles.$onMediaFileOpened.withValue({ opened.append($0) }) {
                let outcome = await LockedAlbumContentProbe.probe(albumDirectory: tempDirectory,
                                                                  keyManager: keyManager,
                                                                  storedKeys: [deviceKey],
                                                                  onFileProbed: { probed.append($0) })
                return (outcome, LockedAlbumKeyProbe.requiredKey(albumDirectory: tempDirectory))
            }
        }

        XCTAssertEqual(outcome, .nothingTested)
        XCTAssertNil(requiredKey)
        XCTAssertEqual(opened.values, [])
        XCTAssertEqual(probed.values, [])
    }

    /// Only downloaded files count toward the sample bound.
    func testContentProbeSamplesOnlyDownloadedFiles() async throws {
        let nameKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        for index in 0..<LockedAlbumContentProbe.maxFilesSampled {
            try await writeMedia(named: "evicted-\(index)", in: tempDirectory, key: nameKey, stamp: false)
        }
        try await writeMedia(named: "local", in: tempDirectory, key: deviceKey, stamp: false)
        let keyManager = DemoKeyManager(keys: [deviceKey])
        keyManager.currentKey = deviceKey
        let probed = Recorder<URL>()

        let outcome = await LockedAlbumProbeFiles.$needsDownload.withValue({ $0.lastPathComponent.hasPrefix("evicted-") }) {
            await LockedAlbumContentProbe.probe(albumDirectory: tempDirectory,
                                                keyManager: keyManager,
                                                storedKeys: [deviceKey],
                                                onFileProbed: { probed.append($0) })
        }

        XCTAssertEqual(outcome, .readable(key: deviceKey, lockedFileNames: []))
        XCTAssertEqual(probed.values.map(\.lastPathComponent), ["local.\(MediaType.photo.encryptedFileExtension)"])
    }

    func testUnchangedProbeOutcomeDoesNotBroadcast() async throws {
        let nameKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        let manager = albumManager(holding: [deviceKey], current: deviceKey)
        await manager.waitForLockedContentProbes()
        let directory = try seedLocalAlbumDirectory(nameKey: nameKey)
        try await writeMedia(named: "a", in: directory, key: nameKey, stamp: false)
        let keyLibrary = manager.keyLibraryIdentity(storedKeys: [deviceKey])
        let broadcasts = Recorder<Void>()
        let subscription = manager.albumOperationPublisher.sink { operation in
            if case .albumsUpdated = operation { broadcasts.append(()) }
        }
        defer { subscription.cancel() }
        let storedKeys = [deviceKey]
        let probe = {
            _ = await manager.startContentProbe(directoryURL: directory,
                                                storageType: .local,
                                                storedKeys: storedKeys,
                                                keyLibrary: keyLibrary).value
            await manager.waitForLockedContentProbes()
            // `onFinished` announces on the main queue.
            await MainActor.run {}
        }

        await probe()
        let afterFirst = broadcasts.values.count
        XCTAssertEqual(afterFirst, 1, "a first result that changes the placeholder is announced")

        // A changed modification date invalidates the entry, as an iCloud Drive
        // folder's does when anything in it changes.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)],
                                              ofItemAtPath: directory.path)
        XCTAssertNil(manager.lockedContentProbes.result(for: directory, keyLibrary: keyLibrary))
        await probe()

        XCTAssertEqual(broadcasts.values.count, afterFirst, "an unchanged result must not trigger a new listing")
    }

    func testUserNameWithTheAlbumPrefixIsNotReportedUnavailable() {
        let album = Album(name: "Album_2024", storageOption: .local, creationDate: Date(), key: deviceKey)

        XCTAssertFalse(album.isNameUnavailable)
        XCTAssertEqual(album.displayName, "Album_2024")
    }

    // MARK: - Opening a locked album

    func testLockedDirectoryAlbumOpensUnderTheGivenKeyWithItsNameUnavailable() throws {
        let foreignKey = try PrivateKey(passphrase: KeyPassphrase(words: foreignPhrase))
        let encryptedName = Album(name: "Holiday", storageOption: .local, creationDate: Date(), key: foreignKey).encryptedPathComponent
        let placeholder = LockedAlbumPlaceholder(encryptedDirectoryName: encryptedName,
                                                 storageOption: .local,
                                                 creationDate: Date())

        let album = placeholder.openableAlbum(key: deviceKey)

        XCTAssertEqual(album.key, deviceKey)
        XCTAssertEqual(album.encryptedPathComponent, encryptedName, "the album must keep its directory")
        XCTAssertNil(album.albumID)
        XCTAssertTrue(album.isNameUnavailable)
        XCTAssertTrue(placeholder.matches(album))
        XCTAssertFalse(placeholder.matches(Album(name: "Other", storageOption: .local, creationDate: Date(), key: deviceKey)))
    }

    func testLockedCloudKitAlbumOpensUnderItsAlbumID() throws {
        let scenario = try makeScenario { _ in nil }
        let placeholder = LockedAlbumPlaceholder(encryptedDirectoryName: scenario.placeholder.encryptedDirectoryName,
                                                 storageOption: .cloudKit,
                                                 creationDate: scenario.placeholder.creationDate,
                                                 albumID: "album-1")

        let album = placeholder.openableAlbum(key: deviceKey)

        XCTAssertEqual(album.albumID, "album-1")
        XCTAssertEqual(album.storageOption, .cloudKit)
        XCTAssertTrue(album.isNameUnavailable)
        XCTAssertTrue(placeholder.matches(album))
        var other = album
        other.albumID = "album-2"
        XCTAssertFalse(placeholder.matches(other))
    }
}
