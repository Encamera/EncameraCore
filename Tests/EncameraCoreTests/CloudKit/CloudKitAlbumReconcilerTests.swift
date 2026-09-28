//
//  CloudKitAlbumReconcilerTests.swift
//  EncameraCoreTests
//
//  Chunk 13: cross-device album materialization. Exercises the record ↔ key
//  matching, the two-way reconcile (pull/push), key-availability gating, and the
//  in-memory store's album CRUD. Filesystem materialization + the full two-device
//  round-trip are covered by the e2e verification in the plan.
//

import XCTest
@testable import EncameraCore

final class CloudKitAlbumReconcilerTests: XCTestCase {

    private var markerIDs: [String] = []

    override func tearDown() {
        for albumID in markerIDs {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
        }
        markerIDs = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// A CloudKit album materialized on this device: a minted id and its
    /// `album.json`, as enumeration would find it.
    private func materializedAlbum(_ name: String, key: PrivateKey,
                                   isHidden: Bool = false, coverMediaID: String? = nil,
                                   dirty: Bool = false) throws -> Album {
        let albumID = UUID().uuidString
        let album = Album(name: name, storageOption: .cloudKit,
                          creationDate: Date(timeIntervalSinceReferenceDate: 790_000_000),
                          key: key, albumID: albumID)
        markerIDs.append(albumID)
        try CloudKitAlbumMarker(album: album, isHidden: isHidden, coverMediaID: coverMediaID, dirty: dirty)
            .write(albumID: albumID)
        return album
    }

    /// The album's record as another device last saved it.
    private func record(for album: Album, encName: String? = nil, isHidden: Bool = false,
                        coverMediaID: String? = nil) -> CloudKitAlbumMetadata {
        CloudKitAlbumMetadata(albumID: album.albumID!,
                              encName: encName ?? album.encryptedPathComponent,
                              createdAt: album.creationDate,
                              isHidden: isHidden,
                              schemaVersion: CloudKitSchema.currentSchemaVersion,
                              keyFingerprint: album.key.keychainLabel,
                              recordChangeTag: "tag",
                              coverMediaID: coverMediaID)
    }

    private func encName(_ name: String, key: PrivateKey) -> String {
        Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key).encryptedPathComponent
    }

    private func changeFeed(changedAlbums: [CloudKitAlbumMetadata]) -> CloudKitChangeSet {
        CloudKitChangeSet(changed: [], deleted: [], changedAlbums: changedAlbums,
                          deletedAlbumIDs: [], token: nil, moreComing: false)
    }

    private func randomKey() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }

    private func makeKey(_ seed: UInt8) -> PrivateKey {
        PrivateKey(name: "key-\(seed)", keyBytes: Array(repeating: seed, count: 32), creationDate: Date())
    }

    /// Build the remote album record exactly as a device would: encName is the
    /// album-name ciphertext under the album's key; albumID is the album's minted id.
    private func remoteRecord(name: String, key: PrivateKey, isHidden: Bool = false,
                              albumID: String = UUID().uuidString) -> CloudKitAlbumMetadata {
        let album = Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key)
        return CloudKitAlbumMetadata(albumID: albumID,
                                     encName: album.encryptedPathComponent,
                                     createdAt: Date(),
                                     isHidden: isHidden,
                                     schemaVersion: CloudKitSchema.currentSchemaVersion,
                                     keyFingerprint: key.keychainLabel,
                                     recordChangeTag: "tag")
    }

    /// A CloudKit album the album manager lists, under a minted id. It has no
    /// `album.json`; `materializedAlbum` writes one.
    private func localAlbum(_ name: String, key: PrivateKey) -> Album {
        Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key,
              albumID: UUID().uuidString)
    }

    private func freshDeleteQueue(_ name: String = #function) -> CloudKitAlbumDeleteQueue {
        CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults(name))
    }

    /// Durable, process-wide state, so each test needs its own — a leftover publish
    /// mark from another test would turn a self-heal push into a delete.
    private func freshPublishRegistry(_ name: String = #function) -> CloudKitAlbumPublishRegistry {
        CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults(name))
    }

    private func makeReconciler(store: CloudKitMediaStoring,
                                keys: [PrivateKey],
                                albums: [Album],
                                deleteQueue: CloudKitAlbumDeleteQueue? = nil,
                                publishRegistry: CloudKitAlbumPublishRegistry? = nil,
                                function: String = #function) -> (CloudKitAlbumReconciler, MockAlbumManager) {
        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = keys
        keyManager.currentKey = keys.first
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = albums
        let reconciler = CloudKitAlbumReconciler(store: store,
                                                 keyManager: keyManager,
                                                 albumManager: albumManager,
                                                 deleteQueue: deleteQueue ?? freshDeleteQueue(function),
                                                 publishRegistry: publishRegistry ?? freshPublishRegistry(function))
        return (reconciler, albumManager)
    }

    // MARK: - match (pure)

    /// A record named by a minted id, as every CloudKit album now is. Nothing about
    /// the id relates to the name or the key.
    private func uuidRecord(name: String, key: PrivateKey) -> CloudKitAlbumMetadata {
        let album = Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key)
        return CloudKitAlbumMetadata(albumID: UUID().uuidString,
                                     encName: album.encryptedPathComponent,
                                     createdAt: Date(),
                                     isHidden: false,
                                     schemaVersion: CloudKitSchema.currentSchemaVersion,
                                     keyFingerprint: key.keychainLabel,
                                     recordChangeTag: "tag")
    }

    /// Well-formed `Album_` base64 that no key authenticates.
    private func garbageEncName() -> String {
        let bytes = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        return "Album_" + bytes.base64EncodedString().replacingOccurrences(of: "/", with: "_")
    }

    func test_match_findsOwningKeyAndRecoversName() {
        let owner = makeKey(7)
        let other = makeKey(3)
        let record = uuidRecord(name: "Vacation", key: owner)

        let result = CloudKitAlbumReconciler.match(record: record, keys: [other, owner])

        XCTAssertEqual(result?.name, "Vacation")
        XCTAssertEqual(result?.key.keyBytes, owner.keyBytes)
    }

    func test_match_returnsNilWhenNoKeyOwnsTheRecord() {
        let owner = makeKey(7)
        let record = uuidRecord(name: "Secret", key: owner)

        XCTAssertNil(CloudKitAlbumReconciler.match(record: record, keys: [makeKey(1), makeKey(2)]))
    }

    /// The fingerprint is only a hint: a name ciphertext the named key cannot
    /// authenticate must not be taken at face value.
    func test_match_rejectsGarbageNameEvenUnderTheFingerprintedKey() {
        let key = makeKey(7)
        let record = CloudKitAlbumMetadata(albumID: UUID().uuidString,
                                           encName: garbageEncName(),
                                           createdAt: Date(),
                                           isHidden: false,
                                           schemaVersion: CloudKitSchema.currentSchemaVersion,
                                           keyFingerprint: key.keychainLabel,
                                           recordChangeTag: "tag")

        XCTAssertNil(CloudKitAlbumReconciler.match(record: record, keys: [key, makeKey(2)]))
    }

    func test_reconcile_locksOutAGarbageNameInsteadOfAdoptingItsCiphertext() async {
        let key = makeKey(7)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(CloudKitAlbumMetadata(albumID: UUID().uuidString,
                                              encName: garbageEncName(),
                                              createdAt: Date(),
                                              isHidden: false,
                                              schemaVersion: CloudKitSchema.currentSchemaVersion,
                                              keyFingerprint: key.keychainLabel,
                                              recordChangeTag: "tag"))
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 1)
        XCTAssertTrue(albumManager.adoptedAlbums.isEmpty,
                      "a name no key authenticates must never be adopted under its ciphertext")
    }

    func test_reconcile_locksOutARecordUnderAKeyThisDeviceDoesNotHold() async {
        let store = MockCloudKitMediaStore()
        store.seedAlbum(uuidRecord(name: "Elsewhere", key: makeKey(9)))
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [makeKey(1), makeKey(2)], albums: [])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 1)
        XCTAssertTrue(albumManager.adoptedAlbums.isEmpty)
    }

    // MARK: - reconcile (push / gating / account)

    func test_reconcile_pushesLocalOnlyAlbumUp() async {
        let key = makeKey(5)
        let local = localAlbum("OnlyHere", key: key)
        let store = MockCloudKitMediaStore()
        let (reconciler, _) = makeReconciler(store: store, keys: [key], albums: [local])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 0)
        XCTAssertEqual(store.savedAlbumCalls.map { $0.albumID }, [local.albumID])
        XCTAssertEqual(store.savedAlbumCalls.first?.keyFingerprint, key.keychainLabel,
                       "the self-heal push must stamp the album with the key that encrypts it")
    }

    func test_reconcile_reportsLockedOutWhenKeyMissing() async {
        let absentOwner = makeKey(9)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Remote", key: absentOwner))
        let (reconciler, _) = makeReconciler(store: store, keys: [makeKey(1)], albums: [])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 1)
        XCTAssertTrue(store.savedAlbumCalls.isEmpty)
    }

    @MainActor
    func testLockedOutAlbumCountIsSurfaced() async {
        LockedAlbumsReporter.shared.report(lockedAlbumCount: 0)

        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "RemoteOne", key: makeKey(9)))
        store.seedAlbum(remoteRecord(name: "RemoteTwo", key: makeKey(8)))

        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = [makeKey(1)]
        keyManager.currentKey = keyManager.storedKeysValue.first
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [localAlbum("Local", key: keyManager.currentKey!)]

        let queue = freshDeleteQueue()
        let registry = freshPublishRegistry()
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false, makeReconciler: { manager in
            CloudKitAlbumReconciler(store: store,
                                    keyManager: manager.keyManager,
                                    albumManager: manager,
                                    deleteQueue: queue,
                                    publishRegistry: registry)
        })

        await sync.syncAll()

        let reported = await sync.albumsNeedingKey
        XCTAssertEqual(reported, 2, "both unreadable remote albums are counted")
        XCTAssertEqual(LockedAlbumsReporter.shared.lockedAlbumCount, 2,
                       "the count must reach the observable the album grid reads")
    }

    /// The banner must clear itself once the keys are present, or it would
    /// permanently accuse the app of hiding albums that are now visible.
    @MainActor
    func testLockedOutCountClearsWhenKeysArePresent() async {
        LockedAlbumsReporter.shared.report(lockedAlbumCount: 3)

        let owner = makeKey(9)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "RemoteOne", key: owner))

        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = [owner]
        keyManager.currentKey = owner
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [localAlbum("Local", key: owner)]

        let queue = freshDeleteQueue()
        let registry = freshPublishRegistry()
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false, makeReconciler: { manager in
            CloudKitAlbumReconciler(store: store,
                                    keyManager: manager.keyManager,
                                    albumManager: manager,
                                    deleteQueue: queue,
                                    publishRegistry: registry)
        })

        await sync.syncAll()

        XCTAssertEqual(albumManager.adoptedAlbums.map { $0.name }, ["RemoteOne"],
                       "the album whose key is present is materialized, not counted as locked out")
        let reported = await sync.albumsNeedingKey
        XCTAssertEqual(reported, 0)
        XCTAssertEqual(LockedAlbumsReporter.shared.lockedAlbumCount, 0)
    }

    /// The CloudKit plane going inactive has to clear the banner too. `report`
    /// is the only writer of the observable, and it sits below the skip guard,
    /// so a count from a flag-on period used to stand for the rest of the
    /// process — naming albums the reconciler had stopped looking for.
    @MainActor
    func testLockedOutCountClearsWhenTheCloudKitPlaneGoesInactive() async {
        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled) }
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)

        LockedAlbumsReporter.shared.report(lockedAlbumCount: 0)

        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = [makeKey(1)]
        keyManager.currentKey = keyManager.storedKeysValue.first
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = []

        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Remote", key: makeKey(9)))
        let queue = freshDeleteQueue()
        let registry = freshPublishRegistry()
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false, makeReconciler: { manager in
            CloudKitAlbumReconciler(store: store,
                                    keyManager: manager.keyManager,
                                    albumManager: manager,
                                    deleteQueue: queue,
                                    publishRegistry: registry)
        })

        await sync.syncAll()
        var reported = await sync.albumsNeedingKey
        XCTAssertEqual(reported, 1, "the unreadable remote album is counted while the plane is active")
        XCTAssertEqual(LockedAlbumsReporter.shared.lockedAlbumCount, 1)

        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        await sync.syncAll()

        reported = await sync.albumsNeedingKey
        XCTAssertEqual(reported, 0)
        XCTAssertEqual(LockedAlbumsReporter.shared.lockedAlbumCount, 0,
                       "a skipped run must not leave the grid claiming albums are locked out")
    }

    func test_reconcile_noOpWhenAccountUnavailable() async {
        let key = makeKey(5)
        let local = localAlbum("Offline", key: key)
        let store = MockCloudKitMediaStore()
        store.accountAvailableValue = false
        let (reconciler, _) = makeReconciler(store: store, keys: [key], albums: [local])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 0)
        XCTAssertEqual(store.fetchChangesCount, 0, "no account means the zone is never read")
        XCTAssertEqual(store.fetchAllAlbumsCount, 0)
        XCTAssertTrue(store.savedAlbumCalls.isEmpty)

        store.accountAvailableValue = true
        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(store.fetchChangesCount, 1)
        XCTAssertEqual(store.fetchAllAlbumsCount, 1)
        XCTAssertEqual(store.savedAlbumCalls.map { $0.albumID }, [local.albumID])
    }

    func test_reconcile_doesNotRePushAlbumAlreadyRemote() async {
        let key = makeKey(5)
        let local = localAlbum("Synced", key: key)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Synced", key: key, albumID: local.albumID!))
        let (reconciler, _) = makeReconciler(store: store, keys: [key], albums: [local])

        _ = await reconciler.reconcileAlbums()

        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "an album already present remotely must not be re-pushed")
    }

    // MARK: - Pull routing through the manager

    func test_reconcile_materializesRemoteAlbumThroughTheManager() async {
        let key = makeKey(5)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "FromOtherDevice", key: key, isHidden: true))
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 0)
        XCTAssertEqual(albumManager.adoptedAlbums.map { $0.name }, ["FromOtherDevice"],
                       "materialization must go through AlbumManaging so observers are notified")
        XCTAssertEqual(albumManager.adoptedAlbums.first?.isHidden, true)
    }

    func test_reconcile_adoptsARemoteAlbumUnderTheRecordsID() async {
        let key = makeKey(5)
        let record = uuidRecord(name: "Minted", key: key)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(record)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [])

        let lockedOut = await reconciler.reconcileAlbums()

        XCTAssertEqual(lockedOut, 0)
        XCTAssertEqual(albumManager.adoptedAlbums.map(\.albumID), [record.albumID],
                       "the album is adopted under the record's id, not one derived from its name")
        XCTAssertEqual(albumManager.adoptedAlbums.first?.encName, record.encName,
                       "adoption keeps the record's name ciphertext rather than minting new ciphertext")
        XCTAssertEqual(albumManager.adoptedAlbums.first?.name, "Minted")
        XCTAssertTrue(store.savedAlbumCalls.isEmpty)
    }

    /// The authoritative cross-device delete: the zone change feed names the album.
    func test_reconcile_removesAlbumTheChangeFeedReportsDeleted() async {
        let key = makeKey(5)
        let local = localAlbum("Gone", key: key)
        let albumID = local.albumID!
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [],
                                            deletedAlbumIDs: [albumID], token: nil, moreComing: false)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [local])

        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(albumManager.remoteDeletedAlbums.map { $0.name }, ["Gone"],
                       "a deleted remote album must be removed via applyRemoteAlbumDeletion so broadcasts, currentAlbum, and hidden-state cleanup all run without touching CloudKit records")
    }

    /// Absence from `fetchAllAlbums` is NOT a delete signal: a `CKQuery` index is
    /// eventually consistent, so a just-created album is routinely missing from it.
    /// Treating that as a deletion would destroy albums at random.
    func test_reconcile_pushesAnAlbumAbsentFromTheQueryButNeverPublished() async {
        let key = makeKey(5)
        let local = localAlbum("BrandNew", key: key)
        let store = MockCloudKitMediaStore()
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [local])

        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(store.savedAlbumCalls.count, 1, "a never-published album is self-healed, not deleted")
        XCTAssertTrue(albumManager.deletedAlbums.isEmpty,
                      "query-index latency must never be read as a deletion")
    }

    /// An album this device HAS seen on the server and that is now absent from the
    /// query is looked up by id. A fetch-by-id that finds no record is authoritative:
    /// the album was deleted elsewhere while the deletion notice was missed (expired
    /// token, long absence). It is removed locally only, since the record is already
    /// gone, and never pushed back up, which would resurrect it on every device.
    func test_reconcile_removesLocallyAPublishedAlbumAbsentFromTheQueryAndNotFoundByID() async {
        let key = makeKey(5)
        let local = localAlbum("WasThere", key: key)
        let albumID = local.albumID!
        let registry = freshPublishRegistry()
        registry.markPublished(albumID)
        let store = MockCloudKitMediaStore()
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [local],
                                                        publishRegistry: registry)

        _ = await reconciler.reconcileAlbums()

        XCTAssertTrue(store.callOrder.contains(.fetchAlbum(albumID: albumID)),
                      "only a fetch by id can prove the record is gone")
        XCTAssertEqual(albumManager.remoteDeletedAlbums.map { $0.name }, ["WasThere"])
        XCTAssertTrue(albumManager.deletedAlbums.isEmpty,
                      "the record is already gone, so the full delete (server record, chunk reclaim) must not run")
        XCTAssertTrue(store.deletedAlbumCalls.isEmpty)
        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "a deleted album must never be pushed back up")
        XCTAssertFalse(registry.isPublished(albumID), "the publish mark goes with the album")
    }

    /// The query index lags a fresh save. A published album missing from
    /// `fetchAllAlbums` whose record a fetch by id still finds is kept, locally and
    /// on the server, so uploads into it keep their parent.
    func test_reconcile_keepsAPublishedAlbumAbsentFromTheQueryButFoundByID() async throws {
        let key = makeKey(5)
        let local = localAlbum("JustCreated", key: key)
        let albumID = local.albumID!
        let registry = freshPublishRegistry()
        registry.markPublished(albumID)
        let store = MockCloudKitMediaStore()
        store.enforceParentAlbumExists = true
        store.seedAlbum(remoteRecord(name: "JustCreated", key: key, albumID: albumID))
        store.albumsMissingFromQuery = [albumID]
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [local],
                                                        publishRegistry: registry)

        _ = await reconciler.reconcileAlbums()

        XCTAssertTrue(albumManager.deletedAlbums.isEmpty, "query-index latency must never be read as a deletion")
        XCTAssertTrue(albumManager.remoteDeletedAlbums.isEmpty)
        XCTAssertTrue(store.deletedAlbumCalls.isEmpty, "the server record must survive")
        XCTAssertTrue(registry.isPublished(albumID))
        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "a clean album the server holds needs no push")
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("recon-\(UUID().uuidString).enc")
        try Data("abc".utf8).write(to: fileURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        _ = try await store.upload(CloudKitMediaUpload(albumID: albumID, mediaID: "m1", mediaType: .photo,
                                                       createdAt: Date(), sizeBytes: 3, encryptedFileURL: fileURL,
                                                       encryptedThumbURL: nil, recordName: "m1", keyFingerprint: ""),
                                   progress: { _ in })
    }

    /// Offline or throttled, the fetch by id proves nothing either way, so the pass
    /// leaves the album alone and asks again next time.
    func test_reconcile_deletesNothingWhenTheFetchByIDFails() async {
        let key = makeKey(5)
        let local = localAlbum("Unknown", key: key)
        let albumID = local.albumID!
        let registry = freshPublishRegistry()
        registry.markPublished(albumID)
        let store = MockCloudKitMediaStore()
        store.fetchAlbumError = CloudKitMediaStoreError.retry(after: 1)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [local],
                                                        publishRegistry: registry)

        _ = await reconciler.reconcileAlbums()

        XCTAssertTrue(albumManager.deletedAlbums.isEmpty)
        XCTAssertTrue(albumManager.remoteDeletedAlbums.isEmpty)
        XCTAssertTrue(store.deletedAlbumCalls.isEmpty)
        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "an unanswered lookup is no reason to push")
        XCTAssertTrue(registry.isPublished(albumID), "the next pass must still know it was published")
    }

    /// The change feed stays authoritative on its own: a published album it reports
    /// deleted is removed without waiting on a fetch by id, even one that would fail.
    func test_reconcile_changeFeedDeletionStillRemovesAPublishedAlbum() async {
        let key = makeKey(5)
        let local = localAlbum("DeletedElsewhere", key: key)
        let albumID = local.albumID!
        let registry = freshPublishRegistry()
        registry.markPublished(albumID)
        let store = MockCloudKitMediaStore()
        store.fetchAlbumError = CloudKitMediaStoreError.retry(after: 1)
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [],
                                            deletedAlbumIDs: [albumID], token: nil, moreComing: false)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [local],
                                                        publishRegistry: registry)

        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(albumManager.remoteDeletedAlbums.map { $0.name }, ["DeletedElsewhere"])
        XCTAssertTrue(albumManager.deletedAlbums.isEmpty)
        XCTAssertTrue(store.deletedAlbumCalls.isEmpty)
        XCTAssertFalse(registry.isPublished(albumID))
    }

    /// Adoption records the publish mark, so the very next pass can tell a later
    /// absence apart from a create that never landed.
    func test_reconcile_marksAdoptedAlbumsAsPublished() async {
        let key = makeKey(5)
        let albumID = UUID().uuidString
        let registry = freshPublishRegistry()
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "FromOtherDevice", key: key, albumID: albumID))
        let (reconciler, _) = makeReconciler(store: store, keys: [key], albums: [], publishRegistry: registry)

        _ = await reconciler.reconcileAlbums()

        XCTAssertTrue(registry.isPublished(albumID))
    }

    func test_reconcile_doesNotOverwriteLocalHiddenStateOfExistingAlbum() async {
        let key = makeKey(5)
        let local = localAlbum("Private", key: key)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Private", key: key, isHidden: false, albumID: local.albumID!))
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [local])
        albumManager.hiddenAlbumNames = ["Private"]

        _ = await reconciler.reconcileAlbums()

        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "the album was recognised as already remote")
        XCTAssertTrue(albumManager.deletedAlbums.isEmpty, "and not treated as absent from the query")
        XCTAssertTrue(albumManager.adoptedAlbums.isEmpty, "an already-materialized album is not re-adopted")
        XCTAssertTrue(albumManager.setHiddenCalls.isEmpty,
                      "an existing album's hidden state must not be driven by the EncAlbum record")
        XCTAssertTrue(albumManager.isAlbumHidden(local))
    }

    // MARK: - Durable pending deletes

    func test_reconcile_drainsPendingDeleteAndDoesNotResurrectAlbum() async {
        let key = makeKey(5)
        let albumID = UUID().uuidString
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Doomed", key: key, albumID: albumID))
        let queue = freshDeleteQueue()
        queue.enqueue(albumID)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [], deleteQueue: queue)

        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(store.deletedAlbumCalls, [albumID], "the pending delete must be drained to the server")
        XCTAssertTrue(queue.pending().isEmpty, "a confirmed delete leaves the queue")
        XCTAssertTrue(albumManager.adoptedAlbums.isEmpty,
                      "a locally-deleted album must not be resurrected from its still-live remote record")
        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "nothing to self-heal push")
    }

    /// A delete the server refuses stays queued, and while it is queued the album
    /// must still not come back from its live remote record.
    func test_reconcile_keepsAFailedDeleteQueuedWithoutResurrectingTheAlbum() async {
        let key = makeKey(5)
        let albumID = UUID().uuidString
        let store = MockCloudKitMediaStore()
        store.seedAlbum(remoteRecord(name: "Doomed", key: key, albumID: albumID))
        store.deleteAlbumError = CloudKitMediaStoreError.retry(after: 1)
        let queue = freshDeleteQueue()
        queue.enqueue(albumID)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [], deleteQueue: queue)

        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(store.deletedAlbumCalls, [albumID], "the delete was attempted and refused")
        XCTAssertEqual(queue.pending(), [albumID], "an unconfirmed delete stays queued for the next pass")
        XCTAssertTrue(albumManager.adoptedAlbums.isEmpty)
        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "a pending-delete album must not be pushed back up")
    }

    // MARK: - In-memory store album CRUD

    func test_inMemoryStore_saveAlbumIsIdempotentAndDeleteRemovesIt() async throws {
        let store = InMemoryCloudKitMediaStore()
        let upload = CloudKitAlbumUpload(albumID: "album-1", encName: "Album_xyz", createdAt: Date(), isHidden: false)

        try await store.saveAlbum(upload)
        try await store.saveAlbum(upload)
        var all = try await store.fetchAllAlbums()
        XCTAssertEqual(all.count, 1)

        try await store.deleteAlbum(albumID: "album-1")
        all = try await store.fetchAllAlbums()
        XCTAssertTrue(all.isEmpty, "a deleted album leaves the zone entirely")

        let changes = try await store.fetchChanges(since: nil)
        XCTAssertEqual(changes.deletedAlbumIDs, ["album-1"],
                       "the change feed is what carries the deletion to other devices")
    }

    /// `EncMedia` parents to `EncAlbum` with `.deleteSelf`, so deleting the album
    /// reclaims its media and their blobs. The soft delete never did this, which is
    /// why deleted albums kept billing quota and re-creating one resurrected its
    /// photos.
    func test_inMemoryStore_deletingAnAlbumCascadesToItsMedia() async throws {
        let store = InMemoryCloudKitMediaStore()
        try await store.saveAlbum(CloudKitAlbumUpload(albumID: "album-1", encName: "Album_xyz",
                                                      createdAt: Date(), isHidden: false))
        let blob = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-\(UUID().uuidString).blob")
        try Data("ciphertext".utf8).write(to: blob)
        defer { try? FileManager.default.removeItem(at: blob) }
        _ = try await store.upload(CloudKitMediaUpload(albumID: "album-1", mediaID: "m1", mediaType: .photo,
                                                       createdAt: Date(), sizeBytes: 10,
                                                       encryptedFileURL: blob, encryptedThumbURL: nil,
                                                       recordName: "m1#0"),
                                   progress: { _ in })
        let seeded = try await store.fetchMetadata(albumID: "album-1", includeThumbnail: false)
        XCTAssertEqual(seeded.count, 1)

        try await store.deleteAlbum(albumID: "album-1")

        let remaining = try await store.fetchMetadata(albumID: "album-1", includeThumbnail: false)
        XCTAssertTrue(remaining.isEmpty, "deleting the album must take its media with it")
        let changes = try await store.fetchChanges(since: nil)
        XCTAssertTrue(changes.deleted.contains("m1#0"), "cascaded media deletions are reported too")
    }

    // MARK: - Remote deletion safety (ENC-301)

    /// A remote album deletion (from the change feed) must NOT enqueue chunk
    /// reclaim — the device that deleted the album already handled the
    /// server side. Routing through `applyRemoteAlbumDeletion` instead of
    /// `delete` avoids calling `deleteCloudKitAlbumRecord`.
    func testRemoteAlbumDeletionDoesNotEnqueueChunkReclaim() async {
        let key = makeKey(5)
        let local = localAlbum("Renamed", key: key)
        let albumID = local.albumID!
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [],
                                            deletedAlbumIDs: [albumID], token: nil, moreComing: false)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [local])

        _ = await reconciler.reconcileAlbums()

        // The album was removed via the local-only path, not the full delete.
        XCTAssertEqual(albumManager.remoteDeletedAlbums.map { $0.name }, ["Renamed"],
                       "change-feed deletions must go through applyRemoteAlbumDeletion, not delete")
        XCTAssertTrue(albumManager.deletedAlbums.isEmpty,
                      "the full delete path (which enqueues chunk reclaim) must NOT be called for remote deletions")
        // The store must not have received any chunk-related calls.
        XCTAssertTrue(store.fetchMetadataCalls.isEmpty,
                      "remote deletion must not enumerate chunk members")
        XCTAssertTrue(store.deletedAlbumCalls.isEmpty,
                      "remote deletion must not call deleteAlbum on the store")
    }

    /// A rename is a field update on the same record: the change feed reports the
    /// record changed, and the album's `album.json` takes the new name in place.
    /// Nothing is deleted or adopted, the blob cache stays, and siblings are untouched.
    func testRemoteRenameRewritesAlbumJSONInPlace() async throws {
        let key = makeKey(5)
        let renamed = try materializedAlbum("OldName", key: key)
        let sibling = try materializedAlbum("Sibling", key: key)
        let siblingMarker = CloudKitAlbumMarker.read(albumID: sibling.albumID!)
        let cacheDir = CloudKitStorageModel(album: renamed).baseURL
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cachedBlob = cacheDir.appendingPathComponent("cached.blob")
        try Data("blob".utf8).write(to: cachedBlob)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let newEncName = encName("NewName", key: key)
        let renamedRecord = record(for: renamed, encName: newEncName)
        let store = MockCloudKitMediaStore()
        store.changeSet = changeFeed(changedAlbums: [renamedRecord])
        store.seedAlbum(renamedRecord)
        store.seedAlbum(record(for: sibling))
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [renamed, sibling])

        _ = await reconciler.reconcileAlbums()

        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: renamed.albumID!))
        XCTAssertEqual(marker.encName, newEncName, "album.json takes the record's name ciphertext")
        XCTAssertEqual(Album.decryptedAlbumName(marker.encName, key: key), "NewName")
        XCTAssertFalse(marker.dirty)
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: sibling.albumID!), siblingMarker,
                       "a sibling's album.json is untouched")
        XCTAssertTrue(albumManager.remoteDeletedAlbums.isEmpty, "a rename deletes nothing")
        XCTAssertTrue(albumManager.deletedAlbums.isEmpty)
        XCTAssertTrue(albumManager.adoptedAlbums.isEmpty, "a rename adopts nothing")
        XCTAssertTrue(store.savedAlbumCalls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedBlob.path), "the blob cache survives a rename")
        XCTAssertEqual(albumManager.notifyAlbumsChangedCount, 1, "observers are told the album list changed")
    }

    func testRemoteHiddenAndCoverChangesAreAppliedToAlbumJSON() async throws {
        let key = makeKey(5)
        let album = try materializedAlbum("Shown", key: key, isHidden: false, coverMediaID: "old-cover")
        let store = MockCloudKitMediaStore()
        let changed = record(for: album, isHidden: true, coverMediaID: "new-cover")
        store.changeSet = changeFeed(changedAlbums: [changed])
        store.seedAlbum(changed)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [album])

        _ = await reconciler.reconcileAlbums()

        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: album.albumID!))
        XCTAssertTrue(marker.isHidden)
        XCTAssertEqual(marker.coverMediaID, "new-cover")
        XCTAssertEqual(marker.encName, album.encryptedPathComponent, "an unchanged name is kept")
        XCTAssertEqual(albumManager.notifyAlbumsChangedCount, 1)
        // Each sidecar instance caches the file at init, so re-read through a new one.
        var sidecarCover = await AlbumCoverSidecar(album: album).coverMediaID()
        for _ in 0..<100 where sidecarCover != "new-cover" {
            try await Task.sleep(nanoseconds: 10_000_000)
            sidecarCover = await AlbumCoverSidecar(album: album).coverMediaID()
        }
        XCTAssertEqual(sidecarCover, "new-cover", "the cover sidecar follows the record")
        try? FileManager.default.removeItem(at: AlbumCoverSidecar.sidecarURL(for: album))
    }

    func testAnUnchangedRecordLeavesAlbumJSONAlone() async throws {
        let key = makeKey(5)
        let album = try materializedAlbum("Steady", key: key, coverMediaID: "c1")
        let before = CloudKitAlbumMarker.read(albumID: album.albumID!)
        let store = MockCloudKitMediaStore()
        let unchanged = record(for: album, coverMediaID: "c1")
        store.changeSet = changeFeed(changedAlbums: [unchanged])
        store.seedAlbum(unchanged)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [album])

        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: album.albumID!), before)
        XCTAssertEqual(albumManager.notifyAlbumsChangedCount, 0)
    }

    /// A dirty marker holds a local change not yet saved; a changed record from the
    /// feed must not overwrite it.
    func testADirtyMarkerIsNotOverwrittenByTheChangeFeed() async throws {
        let key = makeKey(5)
        let album = try materializedAlbum("LocalName", key: key, dirty: true)
        let store = MockCloudKitMediaStore()
        let stale = record(for: album, encName: encName("ServerName", key: key), isHidden: true)
        store.changeSet = changeFeed(changedAlbums: [stale])
        store.seedAlbum(stale)
        store.saveAlbumError = CloudKitMediaStoreError.retry(after: 1)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [album])

        _ = await reconciler.reconcileAlbums()

        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: album.albumID!))
        XCTAssertEqual(Album.decryptedAlbumName(marker.encName, key: key), "LocalName")
        XCTAssertFalse(marker.isHidden)
        XCTAssertTrue(marker.dirty)
        XCTAssertEqual(albumManager.notifyAlbumsChangedCount, 0)
    }

    // MARK: - Dirty push

    /// A local rename not yet saved wins over the name the server still holds:
    /// the record is saved from album.json and the marker is then clean.
    func testADirtyLocalRenameBeatsAStaleServerName() async throws {
        let key = makeKey(5)
        let album = try materializedAlbum("LocalName", key: key, dirty: true)
        let localEncName = album.encryptedPathComponent
        let store = MockCloudKitMediaStore()
        let stale = record(for: album, encName: encName("ServerName", key: key))
        store.changeSet = changeFeed(changedAlbums: [stale])
        store.seedAlbum(stale)
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [album])

        _ = await reconciler.reconcileAlbums()

        let saved = try XCTUnwrap(store.savedAlbumCalls.first)
        XCTAssertEqual(store.savedAlbumCalls.count, 1)
        XCTAssertEqual(saved.albumID, album.albumID)
        XCTAssertEqual(saved.encName, localEncName, "the record takes the local name ciphertext byte for byte")
        XCTAssertEqual(saved.keyFingerprint, key.keychainLabel)
        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: album.albumID!))
        XCTAssertFalse(marker.dirty, "a saved change leaves the marker clean")
        XCTAssertEqual(marker.encName, localEncName)
        XCTAssertTrue(albumManager.adoptedAlbums.isEmpty)
        XCTAssertTrue(albumManager.deletedAlbums.isEmpty)
    }

    /// A save that fails keeps the change pending, and the next pass delivers it.
    func testAFailedDirtyPushStaysDirtyUntilTheNextPassSavesIt() async throws {
        let key = makeKey(5)
        let album = try materializedAlbum("Offline", key: key, dirty: true)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(record(for: album, encName: encName("Before", key: key)))
        store.saveAlbumError = CloudKitMediaStoreError.retry(after: 1)
        let (reconciler, _) = makeReconciler(store: store, keys: [key], albums: [album])

        _ = await reconciler.reconcileAlbums()

        XCTAssertTrue(store.savedAlbumCalls.isEmpty)
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: album.albumID!)?.dirty, true)

        store.saveAlbumError = nil
        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(store.savedAlbumCalls.map(\.encName), [album.encryptedPathComponent])
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: album.albumID!)?.dirty, false)
    }

    /// The pushed hidden flag and cover are album.json's, never the name-keyed
    /// settings the album manager keeps for local albums.
    func testADirtyPushTakesHiddenAndCoverFromAlbumJSON() async throws {
        let key = makeKey(5)
        let album = try materializedAlbum("Marked", key: key, isHidden: true, coverMediaID: "cover-5", dirty: true)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(record(for: album))
        let (reconciler, albumManager) = makeReconciler(store: store, keys: [key], albums: [album])
        XCTAssertFalse(albumManager.isAlbumHidden(album), "precondition: the manager's own flag disagrees")

        _ = await reconciler.reconcileAlbums()

        let saved = try XCTUnwrap(store.savedAlbumCalls.first)
        XCTAssertTrue(saved.isHidden)
        XCTAssertEqual(saved.coverMediaID, "cover-5")
    }

    func testADisabledCoverIsPushedAsNoCoverAndSurvivesTheRecordEcho() async throws {
        let key = makeKey(5)
        let album = try materializedAlbum("NoCover", key: key, coverMediaID: "none", dirty: true)
        let store = MockCloudKitMediaStore()
        let (reconciler, _) = makeReconciler(store: store, keys: [key], albums: [album])

        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(store.savedAlbumCalls.count, 1)
        XCTAssertNil(store.savedAlbumCalls.first?.coverMediaID)
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: album.albumID!)?.dirty, false)

        store.changeSet = changeFeed(changedAlbums: [record(for: album, coverMediaID: nil)])
        _ = await reconciler.reconcileAlbums()

        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: album.albumID!)?.coverMediaID, "none",
                       "the record's missing cover does not turn a disabled cover back on")
    }

    func testACleanAlbumPresentRemotelyIsNotPushed() async throws {
        let key = makeKey(5)
        let album = try materializedAlbum("Clean", key: key)
        let store = MockCloudKitMediaStore()
        store.seedAlbum(record(for: album))
        let (reconciler, _) = makeReconciler(store: store, keys: [key], albums: [album])

        _ = await reconciler.reconcileAlbums()

        XCTAssertTrue(store.savedAlbumCalls.isEmpty)
    }

    // MARK: - Delete queue

    /// The queue's writers race in production (`AlbumManager.delete` enqueues from the
    /// caller's thread while the reconciler drains on the `CloudKitAlbumsSync` actor);
    /// an unsynchronized read-modify-write drops entries computed from stale reads —
    /// and a lost delete intent is exactly the resurrection this queue prevents.
    func test_deleteQueue_concurrentMutationsLoseNoEntries() {
        let queue = freshDeleteQueue()
        for i in 0..<100 { queue.enqueue("stale-\(i)") }
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if i.isMultiple(of: 2) {
                queue.enqueue("fresh-\(i / 2)")
            } else {
                queue.remove("stale-\((i - 1) / 2)")
            }
        }
        let pending = queue.pending()
        XCTAssertEqual(pending.count, 100, "Racing enqueue/remove must not lose entries")
        XCTAssertTrue(pending.allSatisfy { $0.hasPrefix("fresh-") },
                      "All enqueued entries must survive and all removed entries must be gone")
    }
}
