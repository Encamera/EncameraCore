//
//  EncryptedStreamPlaybackSupervisorTests.swift
//  EncameraCoreTests
//
//  AVPlayer timing-dependent tests extracted from EncryptedStreamResourceLoaderTests.
//  These drive real playback through stall/resume/rebuild cycles and assert on
//  player state at precise moments. They are unreliable on the simulator —
//  only run on a physical device.
//

import XCTest
import AVFoundation
import UIKit
@testable import EncameraCore

#if targetEnvironment(simulator)
final class EncryptedStreamPlaybackSupervisorTests: XCTestCase {
    func testSkippedOnSimulator() throws {
        throw XCTSkip("Playback supervisor tests require a real device — AVPlayer timing is unreliable on simulator")
    }
}
#else
final class EncryptedStreamPlaybackSupervisorTests: XCTestCase {

    private let key = [UInt8](repeating: 0x11, count: 32)
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fixture(bytes count: Int) -> Data {
        var data = Data(capacity: count)
        var state: UInt64 = 0xA5A5A5A5DEADC0DE
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            data.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return data
    }

    // MARK: - Helpers

    private actor ThrottledChunkStore: ChunkedBlobStoring {
        private let backing: InMemoryChunkedBlobStore
        private let promptChunks: Int
        private let delay: Duration

        init(backing: InMemoryChunkedBlobStore, promptChunks: Int, delay: Duration) {
            self.backing = backing
            self.promptChunks = promptChunks
            self.delay = delay
        }

        func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
            if index >= promptChunks { try await Task.sleep(for: delay) }
            return try await backing.fetchChunk(mediaRecordName: mediaRecordName, index: index)
        }

        @discardableResult
        func uploadChunks(enc3FileURL: URL, mediaRecordName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
            try await backing.uploadChunks(enc3FileURL: enc3FileURL, mediaRecordName: mediaRecordName, progress: progress)
        }

        func delete(mediaRecordName: String, chunkCount: Int) async throws {
            try await backing.delete(mediaRecordName: mediaRecordName, chunkCount: chunkCount)
        }
    }

    private actor FlakyFirstChunkStore: ChunkedBlobStoring {
        private let backing: ChunkedBlobStoring
        private var failuresRemaining: Int
        private(set) var chunkZeroFetches = 0

        init(backing: ChunkedBlobStoring, failures: Int) {
            self.backing = backing
            self.failuresRemaining = failures
        }

        struct Refused: Error {}

        func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
            if index == 0 {
                chunkZeroFetches += 1
                if failuresRemaining > 0 {
                    failuresRemaining -= 1
                    throw Refused()
                }
            }
            return try await backing.fetchChunk(mediaRecordName: mediaRecordName, index: index)
        }

        @discardableResult
        func uploadChunks(enc3FileURL: URL, mediaRecordName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
            try await backing.uploadChunks(enc3FileURL: enc3FileURL, mediaRecordName: mediaRecordName, progress: progress)
        }

        func delete(mediaRecordName: String, chunkCount: Int) async throws {
            try await backing.delete(mediaRecordName: mediaRecordName, chunkCount: chunkCount)
        }
    }

    private func makeMovieSession(name: String,
                                  seconds: Int,
                                  store: ChunkedBlobStoring,
                                  backing: InMemoryChunkedBlobStore) async throws -> ChunkedStreamSession {
        let movie = tempDir.appendingPathComponent("\(name).mov")
        try await EncryptedStreamResourceLoaderTests.writeTinyMovie(to: movie, seconds: seconds, fastStart: true)
        let enc3 = tempDir.appendingPathComponent("\(name).enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 16 * 1024)
            .encrypt(source: movie, destination: enc3)
        let header = try await backing.uploadChunks(enc3FileURL: enc3, mediaRecordName: name, progress: { _ in })
        return ChunkedStreamSession.open(store: store, mediaRecordName: name, header: header, keyBytes: key, readAhead: 0)
    }

    private func waitUntil(_ timeout: Duration = .seconds(15),
                           _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    @MainActor
    private func describe(_ player: AVPlayer) -> String {
        let item = player.currentItem
        return "status=\(player.timeControlStatus.rawValue) rate=\(player.rate) "
            + "time=\(item.map { CMTimeGetSeconds($0.currentTime()) } ?? -1) "
            + "itemStatus=\(item?.status.rawValue ?? -1) "
            + "error=\(item?.error.map { "\($0)" } ?? "none") "
            + "bufferEmpty=\(item?.isPlaybackBufferEmpty ?? false) keepUp=\(item?.isPlaybackLikelyToKeepUp ?? false)"
    }

    private final class OpenRequestSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var open: Bool
        init(open: Bool) { self.open = open }
        var isOpen: Bool {
            get { lock.withLock { open } }
            set { lock.withLock { open = newValue } }
        }
    }

    @MainActor
    private func playUntilStalled(_ player: AVPlayer, _ item: AVPlayerItem,
                                  after: Double = 0.2, timeout: Duration = .seconds(20)) async throws {
        player.play()
        let stalled = try await waitUntil(timeout) {
            player.timeControlStatus == .paused && item.isPlaybackBufferEmpty
                && item.status == .readyToPlay && CMTimeGetSeconds(item.currentTime()) > after
        }
        XCTAssertTrue(stalled, "the throttled feed never ran the player dry past \(after)s: \(describe(player))")
    }

    // MARK: - Stall resume

    @MainActor
    func testAStreamedPlayerResumesAfterItStallsForData() async throws {
        let movie = tempDir.appendingPathComponent("stall.mov")
        try await EncryptedStreamResourceLoaderTests.writeTinyMovie(to: movie, seconds: 4, fastStart: true)
        let enc3 = tempDir.appendingPathComponent("stall.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 16 * 1024)
            .encrypt(source: movie, destination: enc3)
        let backing = InMemoryChunkedBlobStore()
        let header = try await backing.uploadChunks(enc3FileURL: enc3, mediaRecordName: "stall", progress: { _ in })
        let store = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(400))
        let session = ChunkedStreamSession.open(store: store, mediaRecordName: "stall", header: header, keyBytes: key, readAhead: 0)
        XCTAssertGreaterThan(session.geometry.chunkCount, 12, "the clip must outrun a 400 ms-per-chunk feed")

        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let item = try XCTUnwrap(player.currentItem)
        player.play()

        let duration = try await item.asset.load(.duration)
        var sawPausedWithEmptyBuffer = false
        var reachedEnd = false
        for _ in 0..<600 {
            if item.status == .failed {
                XCTFail("player item failed: \(item.error.map { "\($0)" } ?? "unknown")")
                return
            }
            if player.timeControlStatus == .paused, item.isPlaybackBufferEmpty, item.status == .readyToPlay {
                sawPausedWithEmptyBuffer = true
            }
            if CMTimeGetSeconds(item.currentTime()) >= CMTimeGetSeconds(duration) - 0.5 {
                reachedEnd = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(sawPausedWithEmptyBuffer, "the feed never ran the player dry, so nothing was recovered from")
        XCTAssertTrue(reachedEnd, "the player stopped at \(CMTimeGetSeconds(item.currentTime()))s of "
                      + "\(CMTimeGetSeconds(duration))s — status=\(player.timeControlStatus.rawValue) "
                      + "rate=\(player.rate) bufferEmpty=\(item.isPlaybackBufferEmpty) "
                      + "keepUp=\(item.isPlaybackLikelyToKeepUp)")
        let supervisor = try XCTUnwrap(playback.supervisor, "makePlayer() must install the supervisor")
        XCTAssertGreaterThanOrEqual(supervisor.resumeCount, 1)
        XCTAssertEqual(supervisor.rebuildCount, 0, "a stall is not a failure")

        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    // MARK: - Lifecycle

    @MainActor
    func testTheSupervisorDoesNotKeepThePlayerAlive() async throws {
        let (session, _, _) = try await makeSession(bytes: 2_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)

        weak var weakPlayer: AVPlayer?
        weak var weakItem: AVPlayerItem?
        try autoreleasepool {
            let player = try XCTUnwrap(playback.makePlayer())
            weakPlayer = player
            weakItem = player.currentItem
            XCTAssertNotNil(playback.supervisor)
        }
        let released = try await waitUntil(.seconds(5)) { weakPlayer == nil && weakItem == nil }

        XCTAssertTrue(released, "the supervisor is a second owner of the player: "
                      + "player=\(weakPlayer == nil ? "released" : "alive") item=\(weakItem == nil ? "released" : "alive")")
        XCTAssertNotNil(playback.supervisor, "the supervisor outlives the player it watched")
        try await Task.sleep(for: .milliseconds(300))
        withExtendedLifetime(playback) {}
    }

    @MainActor
    func testDroppingThePlaybackReleasesTheSupervisorAndTheLoader() async throws {
        let (session, _, _) = try await makeSession(bytes: 2_000, chunkSize: 1_000)
        weak var weakSupervisor: StreamingPlaybackSupervisor?
        weak var weakLoader: EncryptedStreamResourceLoader?
        try autoreleasepool {
            let loader = EncryptedStreamResourceLoader(session: session)
            let playback = StreamingPlayback(loader: loader, session: session)
            let player = try XCTUnwrap(playback.makePlayer())
            weakSupervisor = playback.supervisor
            weakLoader = loader
            XCTAssertNotNil(weakSupervisor)
            withExtendedLifetime(player) {}
        }
        let released = try await waitUntil(.seconds(5)) { weakSupervisor == nil && weakLoader == nil }
        XCTAssertTrue(released, "dropping the playback leaked: "
                      + "supervisor=\(weakSupervisor == nil ? "released" : "alive") "
                      + "loader=\(weakLoader == nil ? "released" : "alive")")
    }

    // MARK: - Rebuild

    @MainActor
    func testAFailedItemIsRebuiltAndPlays() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = FlakyFirstChunkStore(backing: backing, failures: 1)
        let session = try await makeMovieSession(name: "rebuild", seconds: 2, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let supervisor = try XCTUnwrap(playback.supervisor)
        let firstItem = try XCTUnwrap(player.currentItem)
        player.play()

        let failed = try await waitUntil(.seconds(45)) { firstItem.status == .failed }
        XCTAssertTrue(failed, "the refused first request must fail the item: \(describe(player))")

        let recovered = try await waitUntil(.seconds(45)) {
            supervisor.rebuildCount == 1
                && player.currentItem !== firstItem
                && player.timeControlStatus == .playing
                && CMTimeGetSeconds(player.currentTime()) > 0.2
        }
        XCTAssertTrue(recovered, "rebuilds=\(supervisor.rebuildCount) \(describe(player))")
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
        let fetches = await store.chunkZeroFetches
        XCTAssertEqual(fetches, 2, "one refused fetch, one that served the rebuilt item")
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    @MainActor
    func testRebuildsStopAtTheBoundAndLeaveTheFailureVisible() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = FlakyFirstChunkStore(backing: backing, failures: StreamingPlaybackSupervisor.maxRebuilds + 1)
        let session = try await makeMovieSession(name: "exhausted", seconds: 2, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let supervisor = try XCTUnwrap(playback.supervisor)
        player.play()

        let exhausted = try await waitUntil(.seconds(45 * (StreamingPlaybackSupervisor.maxRebuilds + 1))) {
            supervisor.rebuildCount == StreamingPlaybackSupervisor.maxRebuilds && player.currentItem?.status == .failed
        }
        XCTAssertTrue(exhausted, "rebuilds=\(supervisor.rebuildCount) \(describe(player))")
        let lastItem = player.currentItem
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(supervisor.rebuildCount, StreamingPlaybackSupervisor.maxRebuilds)
        XCTAssertTrue(player.currentItem === lastItem, "no item may be minted past the bound")
        XCTAssertEqual(player.currentItem?.status, .failed, "the failure must stay visible: \(describe(player))")
        let fetches = await store.chunkZeroFetches
        XCTAssertEqual(fetches, StreamingPlaybackSupervisor.maxRebuilds + 1, "one fetch per item, none after the bound")
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    // MARK: - App lifecycle

    @MainActor
    func testAPauseWhileTheAppIsInactiveIsNotAStall() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(400))
        let session = try await makeMovieSession(name: "inactive", seconds: 8, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let supervisor = try XCTUnwrap(playback.supervisor)
        let item = try XCTUnwrap(player.currentItem)
        player.play()
        let started = try await waitUntil { CMTimeGetSeconds(player.currentTime()) > 0.1 }
        XCTAssertTrue(started, "the clip never started: \(describe(player))")

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let ranDry = try await waitUntil { player.timeControlStatus == .paused && item.isPlaybackBufferEmpty }
        XCTAssertTrue(ranDry, "the throttled feed never ran the player dry: \(describe(player))")
        let refilled = try await waitUntil(.seconds(30)) {
            !item.isPlaybackBufferEmpty && (item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull)
        }
        XCTAssertTrue(refilled, "the feed never caught up, so the resume gate was never open: \(describe(player))")
        try await Task.sleep(for: .seconds(1))

        XCTAssertEqual(player.timeControlStatus, .paused, "an inactive app's player was restarted: \(describe(player))")
        XCTAssertEqual(supervisor.resumeCount, 0)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    @MainActor
    func testStallsAreResumedAgainOnceTheAppIsActive() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(400))
        let session = try await makeMovieSession(name: "reactivated", seconds: 4, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let player = try XCTUnwrap(playback.makePlayer())
        let supervisor = try XCTUnwrap(playback.supervisor)
        let item = try XCTUnwrap(player.currentItem)

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        player.play()

        let duration = try await item.asset.load(.duration)
        let reachedEnd = try await waitUntil(.seconds(40)) {
            CMTimeGetSeconds(item.currentTime()) >= CMTimeGetSeconds(duration) - 0.5
        }
        XCTAssertTrue(reachedEnd, "watching did not resume with the app: \(describe(player))")
        XCTAssertGreaterThanOrEqual(supervisor.resumeCount, 1, "the clip outruns its feed, so a resume was due")
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    // MARK: - Starved stall

    @MainActor
    func testAUserPauseWithAnEmptyBufferIsNeitherResumedNorRebuilt() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = ThrottledChunkStore(backing: backing, promptChunks: 0, delay: .milliseconds(400))
        let session = try await makeMovieSession(name: "emptypause", seconds: 3, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let starvedAfter: TimeInterval = 0.5
        let player = try XCTUnwrap(playback.makePlayer(starvedAfter: starvedAfter, hasOpenDataRequest: { false }))
        let supervisor = try XCTUnwrap(playback.supervisor)
        let item = try XCTUnwrap(player.currentItem)

        player.play()
        let left = try await waitUntil { player.timeControlStatus != .paused }
        XCTAssertTrue(left, "play() must take the player out of paused before the item is ready: \(describe(player))")
        player.pause()
        XCTAssertEqual(player.timeControlStatus, .paused)
        XCTAssertTrue(item.isPlaybackBufferEmpty, "the throttled feed must not have buffered anything yet: \(describe(player))")

        let buffered = try await waitUntil(.seconds(30)) {
            item.status == .readyToPlay && !item.isPlaybackBufferEmpty
                && (item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull)
        }
        XCTAssertTrue(buffered, "the feed never caught up, so nothing was tested: \(describe(player))")
        try await Task.sleep(for: .seconds(starvedAfter * 3 + 1))

        XCTAssertEqual(player.timeControlStatus, .paused, "the user's pause was undone: \(describe(player))")
        XCTAssertEqual(supervisor.resumeCount, 0)
        XCTAssertEqual(supervisor.rebuildCount, 0, "a user pause was rebuilt as a starved stall")
        XCTAssertTrue(player.currentItem === item)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    @MainActor
    func testAStallWithAnOpenRequestIsNotTreatedAsStarved() async throws {
        let backing = InMemoryChunkedBlobStore()
        let store = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(1_500))
        let session = try await makeMovieSession(name: "openstall", seconds: 3, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let starvedAfter: TimeInterval = 0.5
        let player = try XCTUnwrap(playback.makePlayer(starvedAfter: starvedAfter, hasOpenDataRequest: { true }))
        let supervisor = try XCTUnwrap(playback.supervisor)
        let item = try XCTUnwrap(player.currentItem)
        try await playUntilStalled(player, item)

        try await Task.sleep(for: .seconds(starvedAfter * 3))
        XCTAssertEqual(supervisor.rebuildCount, 0, "a stall with a request open was rebuilt: \(describe(player))")
        XCTAssertTrue(player.currentItem === item)

        let duration = try await item.asset.load(.duration)
        let reachedEnd = try await waitUntil(.seconds(60)) {
            CMTimeGetSeconds(item.currentTime()) >= CMTimeGetSeconds(duration) - 0.5
        }
        XCTAssertTrue(reachedEnd, "the ordinary resume path stopped working: \(describe(player))")
        XCTAssertGreaterThanOrEqual(supervisor.resumeCount, 1)
        XCTAssertEqual(supervisor.rebuildCount, 0)
        XCTAssertEqual(supervisor.starvedRebuildCount, 0)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    @MainActor
    func testStarvedRebuildsRespectTheBound() async throws {
        let backing = InMemoryChunkedBlobStore()
        let throttled = ThrottledChunkStore(backing: backing, promptChunks: 4, delay: .milliseconds(1_500))
        let store = FlakyFirstChunkStore(backing: throttled, failures: StreamingPlaybackSupervisor.maxRebuilds)
        let session = try await makeMovieSession(name: "bounded", seconds: 3, store: store, backing: backing)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)
        let starvedAfter: TimeInterval = 0.3
        let player = try XCTUnwrap(playback.makePlayer(starvedAfter: starvedAfter, hasOpenDataRequest: { false }))
        let supervisor = try XCTUnwrap(playback.supervisor)
        player.play()

        let spent = try await waitUntil(.seconds(45 * StreamingPlaybackSupervisor.maxRebuilds)) {
            supervisor.rebuildCount == StreamingPlaybackSupervisor.maxRebuilds && player.currentItem?.status == .readyToPlay
        }
        XCTAssertTrue(spent, "rebuilds=\(supervisor.rebuildCount) \(describe(player))")
        XCTAssertEqual(supervisor.starvedRebuildCount, 0)
        let lastItem = try XCTUnwrap(player.currentItem)

        let stalled = try await waitUntil(.seconds(20)) {
            player.timeControlStatus == .paused && lastItem.isPlaybackBufferEmpty
                && lastItem.status == .readyToPlay && supervisor.isStallPending
        }
        XCTAssertTrue(stalled, "the last item never stalled: \(describe(player))")
        try await Task.sleep(for: .seconds(starvedAfter * 3))
        XCTAssertTrue(player.currentItem === lastItem, "an item was minted past the bound")
        XCTAssertEqual(supervisor.rebuildCount, StreamingPlaybackSupervisor.maxRebuilds)
        XCTAssertEqual(supervisor.starvedRebuildCount, 0)

        let duration = try await lastItem.asset.load(.duration)
        let reachedEnd = try await waitUntil(.seconds(60)) {
            CMTimeGetSeconds(lastItem.currentTime()) >= CMTimeGetSeconds(duration) - 0.5
        }
        XCTAssertTrue(reachedEnd, "the ordinary resume stopped working past the bound: \(describe(player))")
        XCTAssertNotEqual(lastItem.status, .failed)
        XCTAssertGreaterThanOrEqual(supervisor.resumeCount, 1)
        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    // MARK: - Session helpers (shared with EncryptedStreamResourceLoaderTests)

    private func makeSession(bytes: Int, chunkSize: Int)
        async throws -> (session: ChunkedStreamSession, store: InMemoryChunkedBlobStore, plaintext: Data) {
        let plaintext = fixture(bytes: bytes)
        let source = tempDir.appendingPathComponent("src.bin")
        try plaintext.write(to: source)
        let enc3 = tempDir.appendingPathComponent("blob.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: chunkSize)
            .encrypt(source: source, destination: enc3)

        let store = InMemoryChunkedBlobStore()
        let header = try await store.uploadChunks(enc3FileURL: enc3, mediaRecordName: "m", progress: { _ in })
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "m",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 0)
        return (session, store, plaintext)
    }
}
#endif
