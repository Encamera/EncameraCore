//
//  MediaIndexReconcileTests.swift
//  EncameraCoreTests
//
//  Direct unit coverage for the shared MediaIndex reconcile algebra — the
//  upsert / removeComponent / removeEntries primitives and the record-name
//  parser that both the disk and CloudKit backends now mutate the index
//  through. Before this, the merge/remove rules were duplicated across the two
//  backends and only ever exercised end-to-end; these tests pin the algebra as
//  a unit so it can't silently drift.
//

import XCTest
@testable import EncameraCore

final class MediaIndexReconcileTests: XCTestCase {

    private func entry(
        id: String,
        photo: Bool,
        video: Bool,
        dateEncrypted: Date? = nil,
        dateTaken: Date? = nil,
        subtype: MediaFilterOptions = .stillImage
    ) -> MediaIndexEntry {
        MediaIndexEntry(
            id: id,
            hasPhotoComponent: photo,
            hasVideoComponent: video,
            dateEncrypted: dateEncrypted,
            dateTaken: dateTaken,
            subtypeRawValue: subtype.rawValue
        )
    }

    // MARK: - upsert

    func testUpsertNewEntryAdds() {
        var entries: [MediaIndexEntry] = []
        entries.upsert(entry(id: "a", photo: true, video: false))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, "a")
        XCTAssertTrue(entries.first?.hasPhotoComponent ?? false)
    }

    func testUpsertSecondComponentMergesLivePhoto() {
        var entries: [MediaIndexEntry] = []
        entries.upsert(entry(id: "lp", photo: true, video: false))
        entries.upsert(entry(id: "lp", photo: false, video: true))

        XCTAssertEqual(entries.count, 1, "the two components must collapse into one entry")
        let merged = entries.first
        XCTAssertTrue(merged?.hasPhotoComponent ?? false)
        XCTAssertTrue(merged?.hasVideoComponent ?? false)
    }

    func testUpsertFillsNilDatesFromSecondComponent() {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var entries: [MediaIndexEntry] = []
        entries.upsert(entry(id: "lp", photo: true, video: false, dateEncrypted: nil, dateTaken: nil))
        entries.upsert(entry(id: "lp", photo: false, video: true, dateEncrypted: date, dateTaken: date))

        XCTAssertEqual(entries.first?.dateEncrypted, date, "a nil date must fill in from the merging component")
        XCTAssertEqual(entries.first?.dateTaken, date)
    }

    func testUpsertIdempotentLeavesOneUnchangedEntry() {
        let component = entry(id: "a", photo: true, video: false)
        var entries: [MediaIndexEntry] = []
        entries.upsert(component)
        entries.upsert(component)

        XCTAssertEqual(entries.count, 1, "re-upserting an identical component must not duplicate it")
        XCTAssertEqual(entries.first, component, "an idempotent upsert must leave the entry unchanged")
    }

    func testUpsertReturnsTrueOnInsertAndFalseOnIdempotentReupsert() {
        let component = entry(id: "a", photo: true, video: false)
        var entries: [MediaIndexEntry] = []
        XCTAssertTrue(entries.upsert(component), "inserting a new entry must report a change")
        XCTAssertFalse(entries.upsert(component), "re-upserting an identical component must report no change")
    }

    func testUpsertReturnsTrueWhenMergeAddsComponent() {
        var entries: [MediaIndexEntry] = []
        XCTAssertTrue(entries.upsert(entry(id: "lp", photo: true, video: false)))
        XCTAssertTrue(
            entries.upsert(entry(id: "lp", photo: false, video: true)),
            "merging in a previously-absent component must report a change"
        )
        XCTAssertFalse(
            entries.upsert(entry(id: "lp", photo: false, video: true)),
            "merging the same component again must report no change"
        )
    }

    // MARK: - removeComponent

    func testRemoveComponentClearsOneFlagKeepsEntry() {
        var entries = [entry(id: "lp", photo: true, video: true)]
        // "#1" == .video raw value.
        let entryRemoved = entries.removeComponent(recordName: "lp#1")

        XCTAssertFalse(entryRemoved, "clearing one of two components must not remove the entry")
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries.first?.hasPhotoComponent ?? false, "the surviving photo component must remain")
        XCTAssertFalse(entries.first?.hasVideoComponent ?? true, "the removed video component must be cleared")
    }

    func testRemoveLastComponentRemovesEntry() {
        var entries = [entry(id: "p", photo: true, video: false)]
        // "#0" == .photo raw value; removing the only component empties the entry.
        let entryRemoved = entries.removeComponent(recordName: "p#0")

        XCTAssertTrue(entryRemoved)
        XCTAssertTrue(entries.isEmpty)
    }

    func testRemoveByBareMediaIDRemovesWholeEntry() {
        var entries = [entry(id: "lp", photo: true, video: true)]
        let entryRemoved = entries.removeComponent(recordName: "lp")

        XCTAssertTrue(entryRemoved, "a bare media id with no #type removes the whole entry")
        XCTAssertTrue(entries.isEmpty)
    }

    func testRemoveComponentForMissingEntryCountsAsRemoved() {
        var entries = [entry(id: "a", photo: true, video: false)]
        let entryRemoved = entries.removeComponent(recordName: "ghost#0")

        XCTAssertTrue(entryRemoved, "a record name with no matching entry counts as already removed")
        XCTAssertEqual(entries.count, 1, "an unrelated entry must be left alone")
    }

    func testRemoveComponentWithInvalidTypeSuffixRemovesWholeEntry() {
        var entries = [entry(id: "a", photo: true, video: true)]
        // "99" is not a valid MediaType raw value -> treated as a whole-item delete.
        let entryRemoved = entries.removeComponent(recordName: "a#99")

        XCTAssertTrue(entryRemoved)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - removeEntries

    func testRemoveEntriesByIDSet() {
        var entries = [
            entry(id: "a", photo: true, video: false),
            entry(id: "b", photo: true, video: false),
            entry(id: "c", photo: false, video: true)
        ]
        let changed = entries.removeEntries(ids: ["a", "c"])

        XCTAssertTrue(changed)
        XCTAssertEqual(entries.map(\.id), ["b"])
    }

    func testRemoveEntriesNoMatchReturnsFalse() {
        var entries = [entry(id: "a", photo: true, video: false)]
        let changed = entries.removeEntries(ids: ["x", "y"])

        XCTAssertFalse(changed, "removing ids that aren't present must report no change")
        XCTAssertEqual(entries.count, 1)
    }

    func testRemoveEntriesEmptySetReturnsFalse() {
        var entries = [entry(id: "a", photo: true, video: false)]
        let changed = entries.removeEntries(ids: [])

        XCTAssertFalse(changed)
        XCTAssertEqual(entries.count, 1)
    }

    // MARK: - record-name parsing

    func testRecordNameParsingRoundTrips() {
        XCTAssertEqual(MediaRecordName.mediaID(from: "abc#0"), "abc")
        XCTAssertEqual(MediaRecordName.mediaID(from: "abc"), "abc")

        let photo = MediaRecordName.parse("abc#0")
        XCTAssertEqual(photo.id, "abc")
        XCTAssertEqual(photo.type, .photo)

        let video = MediaRecordName.parse("abc#1")
        XCTAssertEqual(video.id, "abc")
        XCTAssertEqual(video.type, .video)

        let bare = MediaRecordName.parse("abc")
        XCTAssertEqual(bare.id, "abc")
        XCTAssertNil(bare.type, "a bare id has no component type")

        let invalid = MediaRecordName.parse("abc#99")
        XCTAssertEqual(invalid.id, "abc")
        XCTAssertNil(invalid.type, "an out-of-range raw value parses as no component type")
    }
}
