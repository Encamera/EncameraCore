//
//  MediaIndexPaginationTests.swift
//  EncameraCoreTests
//
//  Timing and correctness tests for the per-album media index. The timing
//  tests are the success criteria for the pagination work: loading the first
//  page of a 2000-item album must be as fast as a 10-item album — under 0.01s.
//

import XCTest
@testable import EncameraCore

final class MediaIndexPaginationTests: XCTestCase {

    private let pageSize = 60

    // MARK: - Fixtures

    /// Builds `count` synthetic index entries with strictly increasing dates
    /// and a mix of still images, screenshots, videos, and live photos. Every
    /// entry has at least one media component so it always materializes.
    private func makeEntries(count: Int) -> [MediaIndexEntry] {
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        return (0..<count).map { i in
            let subtype: MediaFilterOptions
            let hasPhoto: Bool
            let hasVideo: Bool
            switch i % 3 {
            case 2:
                subtype = .video
                hasPhoto = false
                hasVideo = true
            case 1:
                subtype = .screenshot
                hasPhoto = true
                hasVideo = false
            default:
                subtype = .stillImage
                hasPhoto = true
                hasVideo = (i % 5 == 0) // every fifth still image is a live photo
            }
            return MediaIndexEntry(
                id: UUID().uuidString,
                hasPhotoComponent: hasPhoto,
                hasVideoComponent: hasVideo,
                dateEncrypted: base.addingTimeInterval(Double(i) * 60),
                dateTaken: base.addingTimeInterval(Double(i) * 60 - 3600),
                subtypeRawValue: subtype.rawValue
            )
        }
    }

    private func randomKey() -> [UInt8] {
        (0..<32).map { _ in UInt8.random(in: 0...255) }
    }

    /// A unique temp index path; its parent directory is unique per call so
    /// tests can clean up independently.
    private func tempIndexURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("index.encindex")
    }

    /// Mirrors `InteractableMediaFileAccess.materialize` — pure value construction.
    private func materialize(_ entry: MediaIndexEntry, baseURL: URL) -> InteractableMedia<EncryptedMedia>? {
        var underlying: [EncryptedMedia] = []
        if entry.hasPhotoComponent {
            let url = baseURL.appendingPathComponent("\(entry.id).\(MediaType.photo.encryptedFileExtension)")
            underlying.append(EncryptedMedia(source: .url(url), mediaType: .photo, id: entry.id))
        }
        if entry.hasVideoComponent {
            let url = baseURL.appendingPathComponent("\(entry.id).\(MediaType.video.encryptedFileExtension)")
            underlying.append(EncryptedMedia(source: .url(url), mediaType: .video, id: entry.id))
        }
        guard !underlying.isEmpty else { return nil }
        return try? InteractableMedia(underlyingMedia: underlying)
    }

    // MARK: - Timing tests (success criteria)

    func testFirstPageLoad_N10_under10ms() async throws {
        try await assertFirstPageLoadUnder10ms(entryCount: 10)
    }

    func testFirstPageLoad_N2000_under10ms() async throws {
        try await assertFirstPageLoadUnder10ms(entryCount: 2000)
    }

    /// Loads and pages an album of `entryCount` items straight from the index —
    /// read + decrypt + decode + sort + slice + materialize — and asserts the
    /// first page is produced in under 0.01 seconds.
    private func assertFirstPageLoadUnder10ms(entryCount: Int) async throws {
        let key = randomKey()
        let indexURL = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        // Setup (not measured): build and persist the index once.
        let entries = makeEntries(count: entryCount)
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL).save(MediaIndex(entries: entries))

        let mediaBaseURL = FileManager.default.temporaryDirectory

        func loadFirstPage() async -> (count: Int, elapsed: Duration) {
            let store = MediaIndexStore(keyBytes: key, indexURL: indexURL) // fresh, no cache
            let start = ContinuousClock.now
            guard let index = await store.load() else {
                return (0, .seconds(999))
            }
            let sorted = index.sortedFilteredEntries(
                sortBy: .dateEncrypted(ascending: false),
                filterBy: .all
            )
            let page = sorted.prefix(pageSize).compactMap { materialize($0, baseURL: mediaBaseURL) }
            return (page.count, ContinuousClock.now - start)
        }

        // Warm up one-time costs (libsodium init, etc.), then take the best of
        // several runs to discount scheduler noise.
        _ = await loadFirstPage()
        var best = Duration.seconds(999)
        var samples: [Duration] = []
        for _ in 0..<5 {
            let result = await loadFirstPage()
            XCTAssertEqual(result.count, min(pageSize, entryCount))
            samples.append(result.elapsed)
            best = min(best, result.elapsed)
        }

        print("[MediaIndexPaginationTests] first-page load N=\(entryCount): best=\(best) samples=\(samples)")
        XCTAssertLessThan(
            best,
            .milliseconds(10),
            "First-page load for \(entryCount) items must be under 0.01s (best was \(best))"
        )
    }

    // MARK: - Binary codec

    func testBinaryCodecRoundTrip() throws {
        let entries = makeEntries(count: 250)
        let decoded = try MediaIndexCodec.decode(MediaIndexCodec.encode(entries))
        XCTAssertEqual(decoded, entries)
    }

    func testBinaryCodecRoundTripWithNilDates() throws {
        let entries = [
            MediaIndexEntry(id: UUID().uuidString, hasPhotoComponent: true, hasVideoComponent: false,
                            dateEncrypted: nil, dateTaken: nil,
                            subtypeRawValue: MediaFilterOptions.stillImage.rawValue),
            MediaIndexEntry(id: UUID().uuidString, hasPhotoComponent: false, hasVideoComponent: true,
                            dateEncrypted: Date(), dateTaken: nil,
                            subtypeRawValue: MediaFilterOptions.video.rawValue)
        ]
        let decoded = try MediaIndexCodec.decode(MediaIndexCodec.encode(entries))
        XCTAssertEqual(decoded, entries)
    }

    func testBinaryCodecRejectsCorruptData() {
        XCTAssertThrowsError(try MediaIndexCodec.decode(Data([0, 1, 2, 3])))
    }

    // MARK: - Encryption

    func testEncryptDecryptRoundTrip() throws {
        let key = randomKey()
        let plaintext = MediaIndexCodec.encode(makeEntries(count: 100))
        let encrypted = try MediaIndexStore.encrypt(plaintext, keyBytes: key)
        XCTAssertNotEqual(encrypted, plaintext)
        XCTAssertEqual(try MediaIndexStore.decrypt(encrypted, keyBytes: key), plaintext)
    }

    func testDecryptWithWrongKeyFails() throws {
        let encrypted = try MediaIndexStore.encrypt(
            MediaIndexCodec.encode(makeEntries(count: 10)),
            keyBytes: randomKey()
        )
        XCTAssertThrowsError(try MediaIndexStore.decrypt(encrypted, keyBytes: randomKey()))
    }

    func testStoreSaveLoadRoundTrip() async throws {
        let key = randomKey()
        let indexURL = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let entries = makeEntries(count: 500)
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL).save(MediaIndex(entries: entries))
        let loaded = await MediaIndexStore(keyBytes: key, indexURL: indexURL).load()
        XCTAssertEqual(loaded?.entries, entries)
    }

    func testLoadMissingIndexReturnsNil() async {
        let loaded = await MediaIndexStore(keyBytes: randomKey(), indexURL: tempIndexURL()).load()
        XCTAssertNil(loaded)
    }

    // MARK: - Sorting & filtering

    func testSortByDateEncryptedDescending() {
        let sorted = MediaIndex(entries: makeEntries(count: 100))
            .sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .all)
        for i in 1..<sorted.count {
            XCTAssertGreaterThanOrEqual(sorted[i - 1].dateEncrypted!, sorted[i].dateEncrypted!)
        }
    }

    func testSortByDateTakenAscending() {
        let sorted = MediaIndex(entries: makeEntries(count: 100))
            .sortedFilteredEntries(sortBy: .dateTaken(ascending: true), filterBy: .all)
        for i in 1..<sorted.count {
            XCTAssertLessThanOrEqual(sorted[i - 1].dateTaken!, sorted[i].dateTaken!)
        }
    }

    func testNilDatesSortToEnd() {
        var entries = makeEntries(count: 20)
        entries.insert(
            MediaIndexEntry(id: "v1-legacy", hasPhotoComponent: true, hasVideoComponent: false,
                            dateEncrypted: nil, dateTaken: nil,
                            subtypeRawValue: MediaFilterOptions.stillImage.rawValue),
            at: 10
        )
        let sorted = MediaIndex(entries: entries)
            .sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .all)
        XCTAssertEqual(sorted.last?.id, "v1-legacy")
    }

    func testFilterByVideoOnly() {
        let videos = MediaIndex(entries: makeEntries(count: 300))
            .sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .video)
        XCTAssertFalse(videos.isEmpty)
        for entry in videos {
            XCTAssertEqual(entry.subtypeRawValue, MediaFilterOptions.video.rawValue)
        }
    }

    // MARK: - Pagination

    func testPagingCoversAllEntriesWithoutDuplicates() {
        let sorted = MediaIndex(entries: makeEntries(count: 1000))
            .sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .all)
        var collected: [String] = []
        var offset = 0
        while offset < sorted.count {
            collected.append(contentsOf: sorted[offset..<min(offset + pageSize, sorted.count)].map { $0.id })
            offset += pageSize
        }
        XCTAssertEqual(collected.count, 1000)
        XCTAssertEqual(Set(collected).count, 1000)
        XCTAssertEqual(collected, sorted.map { $0.id })
    }

    // MARK: - Bug #11: Unstable index sort breaks paging

    /// Builds `count` entries that all share the same `dateEncrypted` and
    /// `dateTaken`. IDs are pre-shuffled UUIDs so the insertion order does
    /// not coincide with the expected sorted-by-id order.
    private func makeEntriesWithIdenticalTimestamps(count: Int) -> [MediaIndexEntry] {
        let sameDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
        return (0..<count).map { _ in
            MediaIndexEntry(
                id: UUID().uuidString,
                hasPhotoComponent: true,
                hasVideoComponent: false,
                dateEncrypted: sameDate,
                dateTaken: sameDate,
                subtypeRawValue: MediaFilterOptions.stillImage.rawValue
            )
        }.shuffled()
    }

    /// When many entries share the same `dateEncrypted`, the sort must still
    /// be a total order — pre-fix `compareDates` returned `false` for ties
    /// either way, leaving Swift's sort to break them arbitrarily. The post-
    /// fix tiebreaker on `id` gives a deterministic, repeatable order across
    /// calls so offset-based paging doesn't shuffle items between pages.
    func testEqualTimestampSortIsDeterministicAcrossCalls() {
        let entries = makeEntriesWithIdenticalTimestamps(count: 500)
        let index = MediaIndex(entries: entries)
        let runs = (0..<5).map { _ in
            index.sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .all)
                .map(\.id)
        }
        for run in runs.dropFirst() {
            XCTAssertEqual(run, runs[0],
                           "sortedFilteredEntries must produce the same order across calls when "
                           + "timestamps tie; otherwise offset-based paging can duplicate or skip "
                           + "items across page boundaries.")
        }
    }

    /// The tiebreaker must use `id` so the order is independent of insertion
    /// order. Inserting the same entries shuffled differently must produce
    /// the same sorted output.
    func testEqualTimestampSortIsIndependentOfInsertionOrder() {
        let entries = makeEntriesWithIdenticalTimestamps(count: 400)
        let orderA = MediaIndex(entries: entries.shuffled())
            .sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .all)
            .map(\.id)
        let orderB = MediaIndex(entries: entries.shuffled())
            .sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .all)
            .map(\.id)
        XCTAssertEqual(orderA, orderB,
                       "Shuffling the input must not change the sorted output when timestamps "
                       + "tie — the secondary key (`id`) must drive the ordering.")
    }

    /// The real symptom: page boundaries. Pre-fix, the sort could place
    /// different ties in different positions between calls, so a page-0
    /// snapshot and a page-1 snapshot drawn from separate sort runs would
    /// overlap or skip items.
    func testEqualTimestampPagingHasNoDuplicatesOrSkips() {
        let total = 600
        let pageSize = 50
        let entries = makeEntriesWithIdenticalTimestamps(count: total)
        let index = MediaIndex(entries: entries)

        // Mimic real paging: each page is a fresh sort call, sliced at the
        // page offset. With an unstable sort, page 1's first item could be a
        // duplicate of page 0's last item — or skip the one in between.
        var collected: [String] = []
        var offset = 0
        while offset < total {
            let sorted = index.sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .all)
            collected.append(contentsOf: sorted[offset..<min(offset + pageSize, total)].map(\.id))
            offset += pageSize
        }
        XCTAssertEqual(collected.count, total)
        XCTAssertEqual(Set(collected).count, total,
                       "Paging through equal-timestamp entries duplicated items — the per-call "
                       + "sort order isn't stable, so offset N from one call no longer points at "
                       + "the same item it would have in the previous call.")
    }
}
