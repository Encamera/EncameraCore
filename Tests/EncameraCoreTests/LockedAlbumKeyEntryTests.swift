import XCTest
@testable import EncameraCore

/// Adding the key a locked album needs, gated on the album's recorded
/// fingerprint and proved against its encrypted name.
final class LockedAlbumKeyEntryTests: XCTestCase {

    private var tempDirectory: URL!
    private let deviceKey = PrivateKey(name: "encamera_default_key", keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))

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
        let foreignKey = try manager.deriveKey(from: foreignPhrase, name: AppConstants.defaultKeyName)
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
        let scenario = try makeScenario { .fingerprint($0.keychainLabel) }

        let added = try await addKey(foreignPhrase, manager: scenario.manager, placeholder: scenario.placeholder)

        XCTAssertEqual(added.keychainLabel, scenario.foreignKey.keychainLabel)
        let labels = Set(try scenario.manager.storedKeys().map(\.keychainLabel))
        XCTAssertEqual(labels, [deviceKey.keychainLabel, scenario.foreignKey.keychainLabel])
        XCTAssertEqual(scenario.manager.currentKey?.keyBytes, deviceKey.keyBytes, "an added key must never become current")
    }

    func testMismatchedFingerprintIsRejectedAndSavesNothing() async throws {
        let scenario = try makeScenario { .fingerprint($0.keychainLabel) }

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
        let wrongKey = try scenario.manager.deriveKey(from: wrongPhrase, name: AppConstants.defaultKeyName)
        let stale = LockedAlbumPlaceholder(encryptedDirectoryName: scenario.placeholder.encryptedDirectoryName,
                                           storageOption: .cloudKit,
                                           creationDate: scenario.placeholder.creationDate,
                                           requiredKey: .fingerprint(wrongKey.keychainLabel))

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
        let scenario = try makeScenario { .fingerprint($0.keychainLabel) }
        try scenario.manager.save(key: scenario.foreignKey, setNewKeyToCurrent: false)
        let before = try scenario.manager.storedKeys()

        do {
            _ = try await addKey(foreignPhrase, manager: scenario.manager, placeholder: scenario.placeholder)
            XCTFail("expected .alreadyHeld")
        } catch let error as MissingKeyEntryError {
            XCTAssertEqual(error, .alreadyHeld)
        }

        let after = try scenario.manager.storedKeys()
        XCTAssertEqual(after.map(\.keychainLabel), before.map(\.keychainLabel))
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
        let key = try DemoKeyManager().deriveKey(from: foreignPhrase, name: AppConstants.defaultKeyName)

        XCTAssertEqual(RequiredKeyIdentity.fingerprint(key.keychainLabel).displayLabel,
                       RequiredKeyIdentity.stampPrefix(key.stampPrefix).displayLabel)
        XCTAssertTrue(RequiredKeyIdentity.fingerprint(key.keychainLabel).matches(key))
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
        let key = try DemoKeyManager().deriveKey(from: foreignPhrase, name: AppConstants.defaultKeyName)
        try await writeMedia(named: "a", in: tempDirectory, key: key, stamp: true)
        try await writeMedia(named: "b", in: tempDirectory, key: key, stamp: false)

        XCTAssertEqual(LockedAlbumKeyProbe.requiredKey(albumDirectory: tempDirectory), .stampPrefix(key.stampPrefix))
    }

    func testProbeReportsUnknownForUnstampedMedia() async throws {
        try await writeMedia(named: "a", in: tempDirectory, key: nil, stamp: false)

        XCTAssertNil(LockedAlbumKeyProbe.requiredKey(albumDirectory: tempDirectory))
    }

    func testProbeReportsUnknownWhenStampsDisagree() async throws {
        let key = try DemoKeyManager().deriveKey(from: foreignPhrase, name: AppConstants.defaultKeyName)
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
        let nameKey = try DemoKeyManager().deriveKey(from: foreignPhrase, name: AppConstants.defaultKeyName)
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
        let nameKey = try DemoKeyManager().deriveKey(from: foreignPhrase, name: AppConstants.defaultKeyName)
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
        let nameKey = try DemoKeyManager().deriveKey(from: foreignPhrase, name: AppConstants.defaultKeyName)
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
        let nameKey = try DemoKeyManager().deriveKey(from: foreignPhrase, name: AppConstants.defaultKeyName)
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

        _ = await cache.probe(directory: tempDirectory, keyLibrary: ["a"], run: { .noneOpened }).value

        XCTAssertEqual(cache.outcome(for: tempDirectory, keyLibrary: ["a"]), .noneOpened)
        XCTAssertNil(cache.outcome(for: tempDirectory, keyLibrary: ["a", "b"]))
    }

    func testUserNameWithTheAlbumPrefixIsNotReportedUnavailable() {
        let album = Album(name: "Album_2024", storageOption: .local, creationDate: Date(), key: deviceKey)

        XCTAssertFalse(album.isNameUnavailable)
        XCTAssertEqual(album.displayName, "Album_2024")
    }

    // MARK: - Locked album alert

    /// The Enter Key flow relies on the alert naming the key, so an album whose
    /// contents no key opens must still lead with it.
    func testAlertNamesTheRequiredKeyWhenNoContentsOpened() throws {
        let key = try DemoKeyManager().deriveKey(from: foreignPhrase, name: AppConstants.defaultKeyName)
        let required = RequiredKeyIdentity.stampPrefix(key.stampPrefix)
        let placeholder = LockedAlbumPlaceholder(encryptedDirectoryName: "Album_x",
                                                 storageOption: .local,
                                                 creationDate: Date(),
                                                 requiredKey: required,
                                                 contentsUnreadable: true)

        let keyLine = L10n.MissingKey.albumSubtitleWithFingerprint(required.displayLabel)
        XCTAssertTrue(placeholder.lockedAlertMessage.hasPrefix(keyLine))
        XCTAssertTrue(placeholder.lockedAlertMessage.contains(L10n.MissingKey.albumContentsUnreadable))
    }

    func testAlertWithoutAKnownKeyExplainsNoContentsOpened() {
        let unreadable = LockedAlbumPlaceholder(encryptedDirectoryName: "Album_x", storageOption: .local,
                                                creationDate: Date(), contentsUnreadable: true)
        let unprobed = LockedAlbumPlaceholder(encryptedDirectoryName: "Album_x", storageOption: .local,
                                              creationDate: Date())

        XCTAssertEqual(unreadable.lockedAlertMessage, L10n.MissingKey.albumContentsUnreadable)
        XCTAssertEqual(unprobed.lockedAlertMessage, L10n.MissingKey.subtitleUnknown)
    }
}
