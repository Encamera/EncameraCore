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
    }

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
}
