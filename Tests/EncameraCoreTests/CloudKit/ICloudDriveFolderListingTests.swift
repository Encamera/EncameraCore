//
//  ICloudDriveFolderListingTests.swift
//  EncameraCoreTests
//
//  Album listing reads each iCloud Drive folder's marker off the main thread,
//  and the album step sizes iCloud Drive files off the main actor.
//

import Combine
import XCTest
@testable import EncameraCore

/// Counts marker reads and records whether each ran on the main thread.
private final class MarkerReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []
    private var reading: ICloudDriveFolderMarkerCache.Reading

    init(_ reading: ICloudDriveFolderMarkerCache.Reading) {
        self.reading = reading
    }

    func read(_ folder: URL) -> ICloudDriveFolderMarkerCache.Reading {
        lock.lock()
        defer { lock.unlock() }
        threads.append(Thread.isMainThread)
        return reading
    }

    func setReading(_ newReading: ICloudDriveFolderMarkerCache.Reading) {
        lock.lock()
        defer { lock.unlock() }
        reading = newReading
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return threads.count
    }

    var readsOnMainThread: Int {
        lock.lock()
        defer { lock.unlock() }
        return threads.filter { $0 }.count
    }
}

/// A marker reader that holds every read until the test releases it, so reads
/// overlap the way slow iCloud Drive reads do.
private final class GatedMarkerReader: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let reading: ICloudDriveFolderMarkerCache.Reading

    init(_ reading: ICloudDriveFolderMarkerCache.Reading) {
        self.reading = reading
    }

    func read(_ folder: URL) -> ICloudDriveFolderMarkerCache.Reading {
        gate.wait()
        return reading
    }

    func release(reads count: Int) {
        for _ in 0..<count { gate.signal() }
    }
}

/// Collects the batch flags `readInBackground` hands its callbacks.
private final class BatchFlagRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [Bool] = []

    func append(_ flag: Bool) {
        lock.lock()
        defer { lock.unlock() }
        flags.append(flag)
    }

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return flags
    }
}

/// A clock a test moves forward by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

@MainActor
final class ICloudDriveFolderListingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudDriveFolderListingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let plainFolderReading = ICloudDriveFolderMarkerCache.Reading(marker: .absent, folderPath: "Album_plain")

    private func makeFolder(_ name: String = "Album_plain") throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeManager(recorder: MarkerReadRecorder, clock: ManualClock = ManualClock()) -> AlbumManager {
        let manager = AlbumManager(keyManager: DemoKeyManager(keys: []))
        manager.iCloudDriveFolderMarkers = ICloudDriveFolderMarkerCache(readMarker: { recorder.read($0) },
                                                                        now: { clock.now() })
        return manager
    }

    private func isListed(_ folder: URL,
                          in manager: AlbumManager,
                          linkedFolderAlbumIDs: [String: String] = [:],
                          uncheckedFolders: AlbumManager.UncheckedICloudDriveFolders) -> Bool {
        manager.isListedICloudDriveFolder(folder,
                                          listedCloudKitAlbumIDs: ["ck-album"],
                                          linkedFolderAlbumIDs: linkedFolderAlbumIDs,
                                          deletedAlbumIDs: [],
                                          uncheckedFolders: uncheckedFolders)
    }

    /// Lets every `DispatchQueue.main.async` already queued run.
    private func drainMainQueue() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    // MARK: - Album listing

    func testDisplayListingLeavesOutAnUnreadFolderAndReadsItOffTheMainThread() async throws {
        let folder = try makeFolder()
        let recorder = MarkerReadRecorder(plainFolderReading)
        let manager = makeManager(recorder: recorder)

        XCTAssertFalse(isListed(folder, in: manager, uncheckedFolders: .leaveOutUntilRead),
                       "a folder not read yet stays out of the display list")
        await manager.waitForICloudDriveFolderMarkerReads()

        XCTAssertEqual(recorder.readCount, 1)
        XCTAssertEqual(recorder.readsOnMainThread, 0, "the marker is read off the main thread")
        XCTAssertTrue(isListed(folder, in: manager, uncheckedFolders: .leaveOutUntilRead),
                      "once read, a plain folder is listed")
        XCTAssertEqual(recorder.readCount, 1, "the second listing answers from the cache")
    }

    func testExactListingReadsAnUnreadFolderNowAndOnlyOnce() throws {
        let folder = try makeFolder()
        let recorder = MarkerReadRecorder(plainFolderReading)
        let manager = makeManager(recorder: recorder)

        XCTAssertTrue(isListed(folder, in: manager, uncheckedFolders: .readNow))
        XCTAssertTrue(isListed(folder, in: manager, uncheckedFolders: .readNow))

        XCTAssertEqual(recorder.readCount, 1, "an unchanged folder is read once")
    }

    func testFolderWithNoListedOrDeletedAlbumIsListedWithoutReadingItsMarker() throws {
        let folder = try makeFolder()
        let recorder = MarkerReadRecorder(plainFolderReading)
        let manager = makeManager(recorder: recorder)

        let listed = manager.isListedICloudDriveFolder(folder,
                                                       listedCloudKitAlbumIDs: [],
                                                       linkedFolderAlbumIDs: [:],
                                                       deletedAlbumIDs: [],
                                                       uncheckedFolders: .leaveOutUntilRead)

        XCTAssertTrue(listed)
        XCTAssertEqual(recorder.readCount, 0)
    }

    /// The album step adopts a folder by writing its marker, which changes the
    /// folder, then announces the album list. Until the marker is read again, a
    /// folder the new CloudKit album links stays out of the list, so the album
    /// never shows twice.
    func testFolderLinkedByAListedAlbumStaysOutWhileItsReadingIsOutOfDate() async throws {
        let folder = try makeFolder()
        let recorder = MarkerReadRecorder(plainFolderReading)
        let manager = makeManager(recorder: recorder)
        XCTAssertTrue(isListed(folder, in: manager, uncheckedFolders: .readNow), "precondition: listed as plain")

        try Data("marker".utf8).write(to: folder.appendingPathComponent("marker"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: folder.path)

        XCTAssertFalse(isListed(folder, in: manager,
                                linkedFolderAlbumIDs: ["Album_plain": "ck-album"],
                                uncheckedFolders: .leaveOutUntilRead))
        await manager.waitForICloudDriveFolderMarkerReads()
        XCTAssertEqual(recorder.readCount, 2, "the changed folder is read again")
    }

    func testOutOfDateReadingOfAnUnlinkedFolderKeepsItListedWhileItIsReadAgain() async throws {
        let folder = try makeFolder()
        let recorder = MarkerReadRecorder(plainFolderReading)
        let manager = makeManager(recorder: recorder)
        XCTAssertTrue(isListed(folder, in: manager, uncheckedFolders: .readNow))

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: folder.path)

        XCTAssertTrue(isListed(folder, in: manager, uncheckedFolders: .leaveOutUntilRead),
                      "a plain album does not drop out of the grid while its folder is read again")
        await manager.waitForICloudDriveFolderMarkerReads()
        XCTAssertEqual(recorder.readCount, 2)
    }

    func testReadingDueForRefreshIsUsedAndReadAgainInTheBackground() async throws {
        let folder = try makeFolder()
        let recorder = MarkerReadRecorder(plainFolderReading)
        let clock = ManualClock()
        let manager = makeManager(recorder: recorder, clock: clock)
        XCTAssertTrue(isListed(folder, in: manager, uncheckedFolders: .readNow))

        clock.advance(by: ICloudDriveFolderMarkerCache.maxReadingAge + 1)
        recorder.setReading(.init(marker: .evicted, folderPath: "Album_plain"))

        XCTAssertTrue(isListed(folder, in: manager,
                               linkedFolderAlbumIDs: ["Album_plain": "ck-album"],
                               uncheckedFolders: .readNow),
                      "the cached reading answers while it is read again")
        await manager.waitForICloudDriveFolderMarkerReads()
        XCTAssertEqual(recorder.readCount, 2)
        XCTAssertEqual(recorder.readsOnMainThread, 1, "only the first, exact read ran on the main thread")
        XCTAssertFalse(isListed(folder, in: manager,
                                linkedFolderAlbumIDs: ["Album_plain": "ck-album"],
                                uncheckedFolders: .readNow),
                       "the new reading, an evicted marker of a linked folder, makes it a half")
    }

    func testOverlappingBackgroundReadsCloseOneBatch() async throws {
        let folders = [try makeFolder("Album_one"), try makeFolder("Album_two")]
        let reader = GatedMarkerReader(plainFolderReading)
        let cache = ICloudDriveFolderMarkerCache(readMarker: { reader.read($0) })
        let closedBatches = BatchFlagRecorder()

        for folder in folders {
            cache.readInBackground(folder) { closedBatches.append($0) }
        }
        reader.release(reads: folders.count)
        await cache.waitForReads()

        XCTAssertEqual(closedBatches.values.filter { $0 }.count, 1,
                       "only the last of two overlapping reads closes the batch")
        XCTAssertEqual(closedBatches.values.count, 2)

        cache.readInBackground(folders[0]) { closedBatches.append($0) }
        reader.release(reads: 1)
        await cache.waitForReads()
        XCTAssertEqual(closedBatches.values.last, false, "a read that changes nothing announces nothing")
    }

    func testFinishedBackgroundReadAnnouncesTheAlbumList() async throws {
        let folder = try makeFolder()
        let recorder = MarkerReadRecorder(plainFolderReading)
        let manager = makeManager(recorder: recorder)
        manager.listICloudDriveAlbumFolders = { [] }
        var announcements = 0
        let subscription = manager.albumOperationPublisher.sink { operation in
            if case .albumsUpdated = operation { announcements += 1 }
        }
        defer { subscription.cancel() }

        XCTAssertFalse(isListed(folder, in: manager, uncheckedFolders: .leaveOutUntilRead))
        await manager.waitForICloudDriveFolderMarkerReads()
        await drainMainQueue()

        XCTAssertGreaterThanOrEqual(announcements, 1, "the album list is announced once the folder is read")
    }

    // MARK: - Album step sizing

    func testAlbumStepSizesICloudDriveFilesOffTheMainThread() async throws {
        let downloaded = root.appendingPathComponent("downloaded.encimage")
        try Data(repeating: 1, count: 42).write(to: downloaded)
        let evicted = root.appendingPathComponent("evicted.encvideo")
        let checks = MarkerReadRecorder(plainFolderReading)
        let components = [
            CloudKitMigrationManager.EnumeratedComponent(mediaID: "downloaded", mediaType: .photo,
                                                         createdAt: Date(), url: downloaded),
            CloudKitMigrationManager.EnumeratedComponent(mediaID: "evicted", mediaType: .video,
                                                         createdAt: Date(), url: evicted)
        ]

        let items = await CloudKitMigrationManager.sizedItems(for: components,
                                                             isICloudDrive: true,
                                                             logicalSizes: ["evicted.encvideo": 900],
                                                             isMaterialized: { url in
                                                                 _ = checks.read(url)
                                                                 return url == downloaded
                                                             })

        XCTAssertEqual(checks.readCount, 2)
        XCTAssertEqual(checks.readsOnMainThread, 0, "download-state checks run off the main thread")
        XCTAssertEqual(items.map(\.sizeBytes), [42, 900], "a downloaded file is sized from disk, an evicted one from iCloud")
        XCTAssertEqual(items.map(\.recordName),
                       [CloudKitFileAccess.componentRecordName(mediaID: "downloaded", type: .photo),
                        CloudKitFileAccess.componentRecordName(mediaID: "evicted", type: .video)])
    }
}
