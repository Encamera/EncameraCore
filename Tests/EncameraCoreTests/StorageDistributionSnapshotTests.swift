//
//  StorageDistributionSnapshotTests.swift
//  EncameraCoreTests
//
//  Pins the storage-mix naming and migration-stage rules the visitor profile
//  reports, so a backend CHECK constraint and the client never disagree.
//

import XCTest
@testable import EncameraCore

final class StorageDistributionSnapshotTests: XCTestCase {

    private func randomKey() -> PrivateKey {
        PrivateKey(
            keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) },
            creationDate: Date()
        )
    }

    private func album(_ name: String, on storage: StorageType) -> Album {
        Album(name: name, storageOption: storage, creationDate: Date(), key: randomKey())
    }

    private func build(
        albums: [Album] = [],
        lockedAlbums: [StorageType] = [],
        mediaCount: @escaping (Album) -> Int = { _ in 0 },
        defaultStorage: StorageType = .local,
        hasHadICloudDriveAlbums: Bool = false
    ) -> StorageDistributionSnapshot {
        StorageDistributionSnapshot.build(
            albums: albums,
            lockedAlbums: lockedAlbums,
            mediaCount: mediaCount,
            defaultStorage: defaultStorage,
            hasHadICloudDriveAlbums: hasHadICloudDriveAlbums
        )
    }

    // MARK: - Storage mix

    func testStorageMixNamesEveryCombination() {
        let cases: [(Set<StorageType>, String)] = [
            ([], "none"),
            ([.local], "local"),
            ([.icloud], "icloud"),
            ([.icloud, .local], "icloud+local"),
            ([.cloudKit], "cloudkit"),
            ([.cloudKit, .icloud], "cloudkit+icloud"),
            ([.cloudKit, .local], "cloudkit+local"),
            ([.cloudKit, .icloud, .local], "cloudkit+icloud+local"),
        ]
        for (types, expected) in cases {
            let albums = types.map { album("Album \($0.rawValue)", on: $0) }
            XCTAssertEqual(build(albums: albums).storageMix, expected, "\(types)")
        }
    }

    func testStorageMixIsSortedRegardlessOfAlbumOrder() {
        let albums = [album("b", on: .local), album("a", on: .icloud)]
        XCTAssertEqual(build(albums: albums).storageMix, "icloud+local")
    }

    // MARK: - Counts

    func testAlbumCountsPerStorageType() {
        let snapshot = build(albums: [album("a", on: .icloud), album("b", on: .icloud), album("c", on: .local)])
        XCTAssertEqual(snapshot.albumsICloud, 2)
        XCTAssertEqual(snapshot.albumsLocal, 1)
        XCTAssertEqual(snapshot.albumsCloudKit, 0)
        XCTAssertEqual(snapshot.albumsLocked, 0)
    }

    func testMediaCountsSumPerStorageType() {
        let icloudA = album("a", on: .icloud)
        let icloudB = album("b", on: .icloud)
        let local = album("c", on: .local)
        let counts: [String: Int] = [icloudA.id: 10, icloudB.id: 5, local.id: 3]

        let snapshot = build(albums: [icloudA, icloudB, local], mediaCount: { counts[$0.id] ?? 0 })

        XCTAssertEqual(snapshot.mediaICloud, 15)
        XCTAssertEqual(snapshot.mediaLocal, 3)
        XCTAssertEqual(snapshot.mediaCloudKit, 0)
    }

    func testCloudKitAlbumsAndMediaAreCounted() {
        let cloudKit = album("a", on: .cloudKit)
        let snapshot = build(albums: [cloudKit], mediaCount: { $0.id == cloudKit.id ? 7 : 0 })
        XCTAssertEqual(snapshot.albumsCloudKit, 1)
        XCTAssertEqual(snapshot.mediaCloudKit, 7)
    }

    func testLockedAlbumsCountPerStorageTypeWithNoMedia() {
        let snapshot = build(lockedAlbums: [.cloudKit, .cloudKit])
        XCTAssertEqual(snapshot.albumsLocked, 2)
        XCTAssertEqual(snapshot.albumsCloudKit, 2)
        XCTAssertEqual(snapshot.mediaCloudKit, 0)
        XCTAssertEqual(snapshot.storageMix, "cloudkit")
        XCTAssertEqual(snapshot.migrationStage, .nativeCloudKit)
    }

    func testCloudKitFieldsAreConstantWithoutCloudKitStorage() {
        let snapshot = build(albums: [album("a", on: .icloud)], defaultStorage: .icloud)
        XCTAssertEqual(snapshot.migrationPlansPending, 0)
        XCTAssertFalse(snapshot.isCloudKitAvailable)
        XCTAssertFalse(snapshot.migrationPromptDismissed)
        XCTAssertEqual(snapshot.defaultStorage, .icloud)
        XCTAssertEqual(snapshot.defaultStorageToken, "icloud")
    }

    // MARK: - Migration stage

    func testNoAlbumsStage() {
        XCTAssertEqual(build().migrationStage, .noAlbums)
    }

    func testLocalOnlyStage() {
        XCTAssertEqual(build(albums: [album("a", on: .local)]).migrationStage, .localOnly)
    }

    func testNotStartedStageWithAnyDriveAlbum() {
        XCTAssertEqual(build(albums: [album("a", on: .icloud)]).migrationStage, .notStarted)
        XCTAssertEqual(
            build(albums: [album("a", on: .icloud), album("b", on: .local)]).migrationStage,
            .notStarted
        )
    }

    func testInProgressStageWithDriveAndCloudKitAlbums() {
        XCTAssertEqual(
            build(albums: [album("a", on: .icloud), album("b", on: .cloudKit)]).migrationStage,
            .inProgress
        )
    }

    func testCompletedStageWhenThisDeviceHadDriveAlbums() {
        XCTAssertEqual(
            build(albums: [album("a", on: .cloudKit)], hasHadICloudDriveAlbums: true).migrationStage,
            .completed
        )
    }

    func testNativeCloudKitStageWhenThisDeviceNeverHadDriveAlbums() {
        XCTAssertEqual(build(albums: [album("a", on: .cloudKit)]).migrationStage, .nativeCloudKit)
    }

    func testStageRawValuesMatchTheProfileVocabulary() {
        XCTAssertEqual(
            Set(StorageDistributionSnapshot.MigrationStage.allCases.map(\.rawValue)),
            ["no_albums", "local_only", "native_cloudkit", "not_started", "in_progress", "completed"]
        )
    }
}
