//
//  EncryptedStreamResourceLoaderTests.swift
//  EncameraCoreTests
//
//  The resource loader is the component most likely to hold a subtle bug and the
//  most expensive to iterate on: until now it was only exercised by launching the
//  app (a UI test) or the rig. Neither is necessary for the parts that can be
//  wrong.
//
//  Two layers here:
//
//  1. `resolvedRange` — the byte arithmetic, tested exhaustively. This cannot be
//     covered any other way: `AVAssetResourceLoadingDataRequest` has no public
//     initializer, so the only alternative is driving a real AVPlayer and hoping
//     it happens to issue the edge-case requests.
//  2. `responseSlices` — the slices the player would actually receive, asserted to
//     reassemble into exactly the right plaintext and to touch only the chunks the
//     range overlaps.
//
//  What still needs AVFoundation (and so lives in `ChunkedStreamingLocalUITests`)
//  is whether AVPlayer *accepts* what we hand it — the content-information
//  contract and the unanswered 2-byte data request.
//

import XCTest
import AVFoundation
import UIKit
@testable import EncameraCore

final class EncryptedStreamResourceLoaderTests: XCTestCase {

    private let key = [UInt8](repeating: 0x11, count: 32)
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - resolvedRange

    func testResolvedRangeForAnOrdinaryRequest() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 100, requestedLength: 50, requestsAllToEnd: false, plaintextLength: 1_000)
        XCTAssertEqual(range, 100..<150)
    }

    func testResolvedRangeClampsARequestStraddlingTheEnd() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 900, requestedLength: 500, requestsAllToEnd: false, plaintextLength: 1_000)
        XCTAssertEqual(range, 900..<1_000, "must clamp rather than promise bytes that do not exist")
    }

    func testResolvedRangeForRequestsAllDataToEndOfResource() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 250, requestedLength: 2, requestsAllToEnd: true, plaintextLength: 1_000)
        XCTAssertEqual(range, 250..<1_000, "the requested length is meaningless when all-to-end is set")
    }

    func testResolvedRangeIsEmptyEntirelyPastTheEnd() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 1_000, requestedLength: 10, requestsAllToEnd: false, plaintextLength: 1_000)
        XCTAssertTrue(range.isEmpty, "an offset at or past EOF must yield nothing, not a negative length")
    }

    func testResolvedRangeIsEmptyForZeroLength() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 10, requestedLength: 0, requestsAllToEnd: false, plaintextLength: 1_000)
        XCTAssertTrue(range.isEmpty)
    }

    func testResolvedRangeHandlesAnEmptyResource() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 0, requestedLength: 10, requestsAllToEnd: true, plaintextLength: 0)
        XCTAssertTrue(range.isEmpty)
    }

    func testResolvedRangeClampsANegativeOffset() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: -5, requestedLength: 20, requestsAllToEnd: false, plaintextLength: 1_000)
        XCTAssertEqual(range, 0..<15)
    }

    func testResolvedRangeCoversTheWholeResource() {
        let range = EncryptedStreamResourceLoader.resolvedRange(
            requestedOffset: 0, requestedLength: 0, requestsAllToEnd: true, plaintextLength: 4_096)
        XCTAssertEqual(range, 0..<4_096)
    }

    // MARK: - responseSlices

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> [Data] {
        var out: [Data] = []
        for try await slice in stream { out.append(slice) }
        return out
    }

    func testSlicesReassembleIntoExactlyTheRequestedBytes() async throws {
        let (session, _, plaintext) = try await makeSession(bytes: 10_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)

        for range in [0..<1, 0..<1_000, 999..<1_001, 2_500..<7_500, 9_000..<10_000, 0..<10_000] {
            let slices = try await collect(loader.responseSlices(for: range))
            let joined = slices.reduce(into: Data()) { $0.append($1) }
            XCTAssertEqual(joined, plaintext.subdata(in: range), "range \(range) reassembled wrong")
        }
    }

    /// Incremental delivery is what lets AVPlayer start on a partial buffer instead
    /// of waiting for the whole request, so a multi-chunk range must arrive as
    /// several slices rather than one blob at the end.
    func testAMultiChunkRangeArrivesAsSeveralSlices() async throws {
        let (session, _, _) = try await makeSession(bytes: 10_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)

        let slices = try await collect(loader.responseSlices(for: 0..<3_500))
        XCTAssertEqual(slices.count, 4, "one slice per overlapped chunk")
        XCTAssertEqual(slices.map(\.count), [1_000, 1_000, 1_000, 500])
    }

    func testServingARangeTouchesOnlyTheChunksItOverlaps() async throws {
        let (session, store, _) = try await makeSession(bytes: 100_000, chunkSize: 10_000)
        let loader = EncryptedStreamResourceLoader(session: session)

        _ = try await collect(loader.responseSlices(for: 55_000..<56_000))
        let fetched = await store.fetchedIndices
        XCTAssertEqual(fetched, [5], "a 1 KB range must not pull the file")
    }

    func testAnEmptyRangeYieldsNothingAndFetchesNothing() async throws {
        let (session, store, _) = try await makeSession(bytes: 5_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)

        let slices = try await collect(loader.responseSlices(for: 0..<0))
        XCTAssertTrue(slices.isEmpty)
        let fetched = await store.fetchedIndices
        XCTAssertTrue(fetched.isEmpty)
    }

    /// A tampered or undecryptable chunk must surface as a thrown error so the
    /// loader can fail the request, rather than silently yielding short data — which
    /// AVPlayer would render as corruption.
    func testAnUndecryptableChunkThrowsRatherThanYieldingShortData() async throws {
        let (session, _, _) = try await makeSession(bytes: 5_000, chunkSize: 1_000)
        let wrongKeyReader = SeekableEncryptedReader(keyBytes: [UInt8](repeating: 0x99, count: 32),
                                                     header: session.header,
                                                     provider: session.source)
        let brokenSession = ChunkedStreamSession(mediaRecordName: session.mediaRecordName,
                                                 header: session.header,
                                                 source: session.source,
                                                 reader: wrongKeyReader)
        let loader = EncryptedStreamResourceLoader(session: brokenSession)

        await XCTAssertThrowsErrorAsync(try await collect(loader.responseSlices(for: 0..<2_000))) { error in
            XCTAssertEqual(error as? SeekableFormatError, .chunkAuthenticationFailed(index: 0))
        }
    }

    /// AVFoundation's range requests are far smaller than a chunk, so several
    /// requests land inside one. `PoisonAfterFirstServeProvider` corrupts the second
    /// serve of an index, so a loader that re-decrypted per request would throw here;
    /// the slices are also asserted to be exactly the requested plaintext.
    func testOverlappingRequestsInsideOneChunkDecryptItOnce() async throws {
        let (session, _, plaintext) = try await makeSession(bytes: 10_000, chunkSize: 4_000)
        let spy = PoisonAfterFirstServeProvider(wrapped: session.source)
        let cachingSession = ChunkedStreamSession(
            mediaRecordName: session.mediaRecordName,
            header: session.header,
            source: session.source,
            reader: SeekableEncryptedReader(keyBytes: key, header: session.header, provider: spy))
        let loader = EncryptedStreamResourceLoader(session: cachingSession)

        for range in [0..<500, 500..<1_500, 1_200..<4_000] {
            let slices = try await collect(loader.responseSlices(for: range))
            let joined = slices.reduce(into: Data()) { $0.append($1) }
            XCTAssertEqual(joined, plaintext.subdata(in: range), "range \(range) served wrong bytes")
        }
        let served = await spy.served
        XCTAssertEqual(served, [0], "three requests inside chunk 0 must cost one decrypt")
    }

    func testCancellingTheStreamStopsFetching() async throws {
        let (session, store, _) = try await makeSession(bytes: 100_000, chunkSize: 10_000)
        await store.setChunkLatency(.milliseconds(50))
        let loader = EncryptedStreamResourceLoader(session: session)

        let task = Task { try await collect(loader.responseSlices(for: 0..<100_000)) }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        _ = try? await task.value
        let afterCancel = await store.fetchedIndices.count

        try await Task.sleep(for: .milliseconds(300))
        let settled = await store.fetchedIndices.count
        XCTAssertLessThan(settled, 10, "cancellation must stop the remaining chunk fetches")
        XCTAssertLessThanOrEqual(settled - afterCancel, 1,
                                 "at most the in-flight chunk may land after cancellation")
    }

    // MARK: - Player item wiring

    @MainActor
    func testPlayerItemUsesTheCustomSchemeSoTheDelegateIsConsulted() async throws {
        let (session, _, _) = try await makeSession(bytes: 2_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)
        let item = try XCTUnwrap(loader.makePlayerItem())
        let itemAsset = item.asset
        let asset = try XCTUnwrap(itemAsset as? AVURLAsset)

        // AVFoundation never consults a resource loader for http/https, so getting
        // this wrong produces a video that simply never loads, with no error.
        XCTAssertEqual(asset.url.scheme, EncryptedStreamScheme.scheme)
        XCTAssertEqual(EncryptedStreamScheme.mediaRecordName(from: asset.url), "m")
    }

    /// The item is asked to buffer about one chunk ahead, not the ~18 s the
    /// player settles on by itself over a delegate-fed asset.
    @MainActor
    func testStreamingPlaybackAppliesThePolicyBufferDurationToTheItem() async throws {
        let (session, _, _) = try await makeSession(bytes: 2_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)

        let item = try XCTUnwrap(playback.makePlayerItem())

        XCTAssertEqual(item.preferredForwardBufferDuration,
                       StreamingPlaybackPolicy.cloudKit.preferredForwardBufferDuration)
        XCTAssertGreaterThan(StreamingPlaybackPolicy.cloudKit.preferredForwardBufferDuration, 0,
                             "0 hands the choice back to AVPlayer, which is the wait being tuned away")
    }

    /// The player must not wait to minimize stalls: over a resource loader that
    /// wait held the first frame for two minutes with the item already ready.
    @MainActor
    func testStreamingPlaybackMakesAPlayerThatDoesNotWaitToMinimizeStalls() async throws {
        let (session, _, _) = try await makeSession(bytes: 2_000, chunkSize: 1_000)
        let loader = EncryptedStreamResourceLoader(session: session)
        let playback = StreamingPlayback(loader: loader, session: session)

        let player = try XCTUnwrap(playback.makePlayer())

        XCTAssertFalse(player.automaticallyWaitsToMinimizeStalling)
        XCTAssertFalse(StreamingPlaybackPolicy.cloudKit.automaticallyWaitsToMinimizeStalling)
        let asset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(asset.url.scheme, EncryptedStreamScheme.scheme, "the player must play a loader-backed item")
        XCTAssertEqual(player.currentItem?.preferredForwardBufferDuration,
                       StreamingPlaybackPolicy.cloudKit.preferredForwardBufferDuration)
    }

    private func makeMovieSession(name: String,
                                  seconds: Int,
                                  store: ChunkedBlobStoring,
                                  backing: InMemoryChunkedBlobStore) async throws -> ChunkedStreamSession {
        let movie = tempDir.appendingPathComponent("\(name).mov")
        try await Self.writeTinyMovie(to: movie, seconds: seconds, fastStart: true)
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

    /// `contentLength` must be the PLAINTEXT length. Reporting the ENC3 file size
    /// would make AVPlayer request bytes past the end of the media and mis-seek.
    func testSessionReportsPlaintextLengthNotCiphertextLength() async throws {
        let (session, _, plaintext) = try await makeSession(bytes: 10_000, chunkSize: 1_000)
        XCTAssertEqual(session.plaintextLength, plaintext.count)
        XCTAssertLessThan(session.plaintextLength, session.geometry.totalCiphertextLength,
                          "ciphertext is strictly larger; the two must not be confused")
    }

    // MARK: - The AVFoundation contract, driven by a real AVPlayer

    /// The one thing the slices tests above cannot prove: that AVFoundation
    /// *accepts* what the delegate hands it, end to end — custom scheme, delegate
    /// wiring, content information, byte-range requests, decryption, and a real
    /// decode.
    ///
    /// Runs here rather than in a UI test because the unit bundle has a host app, so
    /// AVPlayer works: a ~15s app launch becomes a sub-second check.
    ///
    /// **Scope, established by mutation-testing rather than assumed.** This test
    /// does NOT catch either of the two contract details the loader is careful
    /// about: answering the ~2-byte data request attached to the info request, and
    /// reporting the ciphertext length as `contentLength`. Both mutations leave it
    /// passing on iOS 26 — AVFoundation tolerates them for a short clip. What it
    /// does catch is a broken scheme or delegate wiring, wrong geometry, a bad
    /// range mapping, and any decryption failure; those are the failures that
    /// actually produce a black frame.
    @MainActor
    func testRealAVPlayerBecomesReadyAndDecodesAFrameThroughTheLoader() async throws {
        let movie = tempDir.appendingPathComponent("clip.mov")
        try await Self.writeTinyMovie(to: movie, seconds: 2)

        let enc3 = tempDir.appendingPathComponent("clip.enc3")
        // 16 KB chunks so even a short clip spans many chunks.
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 16 * 1024)
            .encrypt(source: movie, destination: enc3)

        let store = InMemoryChunkedBlobStore()
        let header = try await store.uploadChunks(enc3FileURL: enc3, mediaRecordName: "clip", progress: { _ in })
        let session = ChunkedStreamSession.open(store: store,
                                                mediaRecordName: "clip",
                                                header: header,
                                                keyBytes: key,
                                                readAhead: 3)
        XCTAssertGreaterThan(session.geometry.chunkCount, 4, "fixture should span several chunks")

        let loader = EncryptedStreamResourceLoader(session: session)
        let item = try XCTUnwrap(loader.makePlayerItem())
        let player = AVPlayer(playerItem: item)

        var ready = false
        for _ in 0..<200 {
            if item.status == .readyToPlay { ready = true; break }
            if item.status == .failed {
                XCTFail("player item failed: \(item.error.map { "\($0)" } ?? "unknown")")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(ready, "AVPlayer never accepted the streamed asset")

        let duration = try await item.asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.5,
                       "the streamed asset must report the real duration")

        // A frame can only decode if chunks were fetched, authenticated, decrypted
        // and reassembled into a valid MOV byte range.
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)

        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// Every loading request AVFoundation issues is traced from receipt to its
    /// outcome, so a stall on a device can be read as "the player stopped asking"
    /// or "the loader stopped answering" from the log alone.
    ///
    /// Asserted per request and in sequence, not by set membership: `received`
    /// first; exactly one outcome (`finished`, `cancelled` or `failed`) and it is the
    /// last line; `contentInfo` only on the information request, straight after
    /// receipt and before its `finished`; only `slice` lines in between, with
    /// `chunk=` and `total=` strictly increasing. The one tolerance is the slice
    /// already past the loader's cancellation check when `didCancel` lands: it may
    /// still trace after `cancelled`, the same in-flight allowance
    /// `testCancellingTheStreamStopsFetching` makes. Nothing may follow `finished`.
    ///
    /// This is also the guard that a fully served data request is *finished* rather
    /// than left open. `AVAssetResourceLoadingRequest` has no public initializer, so
    /// there is no fake to observe `finishLoading()` on; the `finished` line the loader
    /// emits immediately after that call is the observable, and at least one data
    /// request that delivered slices must reach it.
    @MainActor
    func testEveryLoadingRequestIsTracedFromReceiptToOutcome() async throws {
        let movie = tempDir.appendingPathComponent("traced.mov")
        try await Self.writeTinyMovie(to: movie, seconds: 1)
        let enc3 = tempDir.appendingPathComponent("traced.enc3")
        try SeekableEncryptedWriter(keyBytes: key, chunkSize: 16 * 1024)
            .encrypt(source: movie, destination: enc3)
        let store = InMemoryChunkedBlobStore()
        let header = try await store.uploadChunks(enc3FileURL: enc3, mediaRecordName: "traced", progress: { _ in })
        let session = ChunkedStreamSession.open(store: store, mediaRecordName: "traced", header: header, keyBytes: key)

        let loader = EncryptedStreamResourceLoader(session: session)
        let lines = LockedLines()
        loader.traceSink = { lines.append($0) }
        let item = try XCTUnwrap(loader.makePlayerItem())
        let player = AVPlayer(playerItem: item)

        var polls = 0
        while item.status == .unknown, polls < 200 {
            try await Task.sleep(for: .milliseconds(50))
            polls += 1
        }
        XCTAssertEqual(item.status, .readyToPlay, "item error: \(item.error.map { "\($0)" } ?? "none")")

        // Wait until every request received so far has an outcome and the trace has
        // gone quiet, so a request AVFoundation issues after readiness is judged on
        // its outcome rather than on where the snapshot happened to fall. A request
        // that never reaches an outcome runs this to the deadline and fails below.
        var trace = lines.snapshot()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(250))
            let next = lines.snapshot()
            let quiet = next.count == trace.count
            trace = next
            if quiet, Self.requests(in: trace).allSatisfy({ $0.events.contains { Self.outcomes.contains($0.kind) } }) {
                break
            }
        }

        XCTAssertTrue(trace.allSatisfy { !$0.contains("\n") }, "one line per event")
        let requests = Self.requests(in: trace)
        XCTAssertFalse(requests.isEmpty, "no loading request was traced: \(trace)")
        XCTAssertEqual(requests.count, Set(requests.map(\.id)).count, "request ids must be unique: \(trace)")
        for line in trace where Self.parse(line) == nil {
            XCTFail("unparseable trace line: \(line)")
        }

        var informationRequests = 0
        var fullyServedDataRequests = 0
        for request in requests {
            let events = request.events
            let kinds = events.map(\.kind)
            let label = "request \(request.id) \(kinds)"

            XCTAssertEqual(kinds.first, "received", "\(label): an outcome was traced for a request that was never received: \(trace)")
            let outcomeIndices = kinds.indices.filter { Self.outcomes.contains(kinds[$0]) }
            XCTAssertEqual(outcomeIndices.count, 1, "\(label): every request must reach exactly one outcome within the wait: \(trace)")
            guard let received = events.first, received.kind == "received", let outcomeIndex = outcomeIndices.first else { continue }
            let outcome = events[outcomeIndex]
            XCTAssertNotEqual(outcome.kind, "failed", "\(label): no request should fail: \(trace)")

            let between = kinds[1..<outcomeIndex]
            XCTAssertTrue(between.allSatisfy { $0 == "contentInfo" || $0 == "slice" },
                          "\(label): only contentInfo and slice lines may appear between receipt and outcome")
            let after = kinds[(outcomeIndex + 1)...]
            if outcome.kind == "cancelled" {
                XCTAssertTrue(after.count <= 1 && after.allSatisfy { $0 == "slice" },
                              "\(label): only the one slice already past the cancellation check may trace after cancelled")
            } else {
                XCTAssertTrue(after.isEmpty, "\(label): \(outcome.kind) must be the last line traced for the request: \(trace)")
            }

            let slices = events.filter { $0.kind == "slice" }
            let infoLines = events.filter { $0.kind == "contentInfo" }
            if received.fields["info"] == "true" {
                informationRequests += 1
                XCTAssertEqual(kinds, ["received", "contentInfo", "finished"],
                               "\(label): the content-information request is answered on receipt and finished synchronously, "
                               + "with its attached data request left unanswered")
                XCTAssertEqual(infoLines.first?.fields["length"], "\(session.plaintextLength)",
                               "\(label): contentInfo must report the plaintext length")
            } else {
                XCTAssertTrue(infoLines.isEmpty, "\(label): contentInfo traced for a plain data request")
            }

            let chunks = slices.compactMap { $0.fields["chunk"].flatMap(Int.init) }
            let bytes = slices.compactMap { $0.fields["bytes"].flatMap(Int.init) }
            let totals = slices.compactMap { $0.fields["total"].flatMap(Int.init) }
            XCTAssertEqual(chunks.count, slices.count, "\(label): every slice must name its chunk")
            XCTAssertEqual(totals.count, slices.count, "\(label): every slice must carry the running total")
            XCTAssertTrue(zip(chunks, chunks.dropFirst()).allSatisfy { $0 < $1 },
                          "\(label): slices must arrive in strictly ascending chunk order: \(chunks)")
            XCTAssertTrue(zip(totals, totals.dropFirst()).allSatisfy { $0 < $1 },
                          "\(label): the running total must strictly increase: \(totals)")
            var running = 0
            let cumulative = bytes.map { running += $0; return running }
            XCTAssertEqual(totals, cumulative, "\(label): total= must be the sum of the slices so far")

            if outcome.kind == "finished" {
                XCTAssertEqual(outcome.fields["bytes"].flatMap(Int.init), totals.last ?? 0,
                               "\(label): finished must report the bytes the slices delivered")
                if received.fields["info"] != "true", !slices.isEmpty { fullyServedDataRequests += 1 }
            }
        }

        XCTAssertEqual(informationRequests, 1, "exactly one content-information request is expected: \(trace)")
        XCTAssertGreaterThan(requests.count, informationRequests,
                             "AVFoundation must have followed up with a data request: \(trace)")
        XCTAssertGreaterThan(fullyServedDataRequests, 0,
                             "no data request was served to completion and finished; a request left open after its last "
                             + "slice is exactly the stall this trace exists to diagnose: \(trace)")

        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    /// `hasOpenDataRequest` is what tells a stalled player apart from one that
    /// has stopped asking, so it must hold only while a data request is being
    /// served: not for the content-information request, which is answered on
    /// receipt, and not once every request has finished or been cancelled.
    @MainActor
    func testHasOpenDataRequestHoldsOnlyWhileADataRequestIsBeingServed() async throws {
        let store = InMemoryChunkedBlobStore()
        let session = try await makeMovieSession(name: "open", seconds: 1, store: store, backing: store)
        await store.setChunkLatency(.milliseconds(300))
        let loader = EncryptedStreamResourceLoader(session: session)
        XCTAssertFalse(loader.hasOpenDataRequest, "nothing has been asked for yet")

        // Sampled from inside the sink, so each line carries the property's
        // value at the moment the event happened.
        let observed = LockedLines()
        loader.traceSink = { [weak loader] line in
            guard let loader else { return }
            observed.append("\(line) open=\(loader.hasOpenDataRequest) count=\(loader.openDataRequestCount)")
        }
        let item = try XCTUnwrap(loader.makePlayerItem())
        let player = AVPlayer(playerItem: item)

        let sawSlice = try await waitUntil(.seconds(15)) {
            observed.snapshot().contains { $0.hasPrefix("loadingRequest slice") }
        }
        XCTAssertTrue(sawSlice, "no data request was served: \(observed.snapshot())")
        let lines = observed.snapshot()
        let infoLines = lines.filter { $0.hasPrefix("loadingRequest contentInfo") }
        XCTAssertFalse(infoLines.isEmpty, "the content-information request was not traced: \(lines)")
        for line in infoLines {
            XCTAssertTrue(line.hasSuffix(" open=false count=0"),
                          "the content-information request must not count as an open data request: \(line)")
        }
        for line in lines where line.hasPrefix("loadingRequest slice") {
            XCTAssertTrue(line.contains(" open=true"), "a request mid-delivery is open: \(line)")
        }

        // Taking the item away cancels whatever is still outstanding.
        player.replaceCurrentItem(with: nil)
        let settled = try await waitUntil(.seconds(15)) { !loader.hasOpenDataRequest }
        XCTAssertTrue(settled, "requests still open after the item was dropped: \(observed.snapshot())")
        XCTAssertEqual(loader.openDataRequestCount, 0)
        let outcomes = observed.snapshot().filter {
            $0.hasPrefix("loadingRequest finished") || $0.hasPrefix("loadingRequest cancelled")
        }
        XCTAssertFalse(outcomes.isEmpty, "every request must reach finished or cancelled: \(observed.snapshot())")

        withExtendedLifetime(loader) {}
        withExtendedLifetime(player) {}
    }

    private static let outcomes: Set<String> = ["finished", "cancelled", "failed"]

    private struct TraceEvent {
        let kind: String
        let id: Int
        let fields: [String: String]
    }

    /// `loadingRequest <kind> id=<n> key=value …`; tokens without `=` are flags and ignored.
    private static func parse(_ line: String) -> TraceEvent? {
        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.count >= 3, tokens[0] == "loadingRequest" else { return nil }
        var fields: [String: String] = [:]
        for token in tokens.dropFirst(2) {
            guard let eq = token.firstIndex(of: "=") else { continue }
            fields[String(token[..<eq])] = String(token[token.index(after: eq)...])
        }
        guard let id = fields["id"].flatMap(Int.init) else { return nil }
        return TraceEvent(kind: tokens[1], id: id, fields: fields)
    }

    /// The trace grouped per request id, each request's events in emission order,
    /// requests in order of first appearance.
    private static func requests(in trace: [String]) -> [(id: Int, events: [TraceEvent])] {
        var order: [Int] = []
        var byID: [Int: [TraceEvent]] = [:]
        for event in trace.compactMap(parse) {
            if byID[event.id] == nil { order.append(event.id) }
            byID[event.id, default: []].append(event)
        }
        return order.map { ($0, byID[$0] ?? []) }
    }

    private final class LockedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        func snapshot() -> [String] { lock.withLock { lines } }
    }

    static func writeTinyMovie(to url: URL, seconds: Int, fastStart: Bool = false) async throws {
        let side = 240
        let fps: Int32 = 15
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = fastStart
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var state: UInt64 = 0x13579BDF2468ACE0
        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let pointer = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<side {
                    let row = pointer + y * bytesPerRow
                    for x in stride(from: 0, to: side * 4, by: 4) {
                        state = state &* 6364136223846793005 &+ 1442695040888963407
                        let value = UInt8(truncatingIfNeeded: state >> 33)
                        row[x] = 255
                        row[x + 1] = value
                        row[x + 2] = value &+ 61
                        row[x + 3] = value &+ 127
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
