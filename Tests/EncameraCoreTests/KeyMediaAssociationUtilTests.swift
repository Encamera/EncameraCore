import XCTest
@testable import EncameraCore

final class KeyMediaAssociationUtilTests: XCTestCase {

    private let keyA = PrivateKey(keyBytes: Array(repeating: 1, count: 32), creationDate: Date(timeIntervalSince1970: 1_000))
    private let keyB = PrivateKey(keyBytes: Array(repeating: 2, count: 32), creationDate: Date(timeIntervalSince1970: 2_000))
    private let keyC = PrivateKey(keyBytes: Array(repeating: 3, count: 32), creationDate: Date(timeIntervalSince1970: 3_000))

    private func album(_ name: String, key: PrivateKey) -> Album {
        Album(name: name, storageOption: .local, creationDate: Date(), key: key)
    }

    func testGroupsAlbumsUnderTheirKeyWithCounts() {
        let family = album("Family", key: keyA)
        let travel = album("Travel", key: keyA)
        let receipts = album("Receipts", key: keyB)
        let counts = [family.id: 10, travel.id: 40, receipts.id: 5]

        let report = KeyMediaAssociationUtil.report(keys: [keyA, keyB],
                                                    albums: [family, travel, receipts],
                                                    multiDeviceState: nil, currentDeviceID: "this-device", mediaCount: { counts[$0.id] ?? 0 })

        let usageA = report.usage(forKeyFingerprint: keyA.keyFingerprint)
        XCTAssertEqual(usageA?.albums.map(\.album.name), ["Travel", "Family"])
        XCTAssertEqual(usageA?.albums.map(\.mediaCount), [40, 10])
        XCTAssertEqual(usageA?.totalMediaCount, 50)
        XCTAssertEqual(report.usage(forKeyFingerprint: keyB.keyFingerprint)?.totalMediaCount, 5)
    }

    func testKeysAreSortedByTotalMediaCount() {
        let small = album("Small", key: keyA)
        let large = album("Large", key: keyB)
        let counts = [small.id: 3, large.id: 300]

        let report = KeyMediaAssociationUtil.report(keys: [keyA, keyB, keyC],
                                                    albums: [small, large],
                                                    multiDeviceState: nil, currentDeviceID: "this-device", mediaCount: { counts[$0.id] ?? 0 })

        XCTAssertEqual(report.keys.map(\.key.keyFingerprint),
                       [keyB.keyFingerprint, keyA.keyFingerprint, keyC.keyFingerprint])
    }

    func testKeyWithoutAlbumsIsListedEmpty() {
        let report = KeyMediaAssociationUtil.report(keys: [keyC], albums: [], multiDeviceState: nil, currentDeviceID: "this-device", mediaCount: { _ in 0 })

        XCTAssertEqual(report.keys.count, 1)
        XCTAssertEqual(report.keys.first?.albums.count, 0)
        XCTAssertEqual(report.keys.first?.totalMediaCount, 0)
    }

    func testAlbumWhoseKeyIsNotStoredGetsItsOwnEntry() {
        let orphan = album("Orphan", key: keyC)

        let report = KeyMediaAssociationUtil.report(keys: [keyA], albums: [orphan], multiDeviceState: nil, currentDeviceID: "this-device", mediaCount: { _ in 7 })

        XCTAssertEqual(report.usage(forKeyFingerprint: keyC.keyFingerprint)?.albums.map(\.album.name), ["Orphan"])
        XCTAssertEqual(report.keys.first?.key.keyFingerprint, keyC.keyFingerprint)
    }

    func testKeyStoredTwiceIsListedOnce() {
        let copy = PrivateKey(keyBytes: keyA.keyBytes, creationDate: keyA.creationDate)

        let report = KeyMediaAssociationUtil.report(keys: [keyA, copy], albums: [], multiDeviceState: nil, currentDeviceID: "this-device", mediaCount: { _ in 0 })

        XCTAssertEqual(report.keys.count, 1)
    }

    func testOriginComesFromTheMultiDeviceState() {
        let state = MultiDeviceState(
            devices: [MultiDeviceState.DeviceRecord(deviceID: "other", name: "Alex's iPad", lastSeen: Date())],
            keyFingerprints: [keyA.keyFingerprint, keyB.keyFingerprint, keyC.keyFingerprint],
            keyOrigins: [keyA.keyFingerprint: "this-device", keyB.keyFingerprint: "other", keyC.keyFingerprint: "evicted"]
        )
        let keyD = PrivateKey(keyBytes: Array(repeating: 4, count: 32), creationDate: Date())
        let keyE = PrivateKey(keyBytes: Array(repeating: 5, count: 32), creationDate: Date())
        var withUnclaimed = state
        withUnclaimed.keyFingerprints.append(keyD.keyFingerprint)

        let report = KeyMediaAssociationUtil.report(keys: [keyA, keyB, keyC, keyD, keyE], albums: [],
                                                    multiDeviceState: withUnclaimed, currentDeviceID: "this-device",
                                                    mediaCount: { _ in 0 })

        XCTAssertEqual(report.usage(forKeyFingerprint: keyA.keyFingerprint)?.origin, .thisDevice)
        XCTAssertEqual(report.usage(forKeyFingerprint: keyB.keyFingerprint)?.origin, .otherDevice(name: "Alex's iPad"))
        XCTAssertEqual(report.usage(forKeyFingerprint: keyC.keyFingerprint)?.origin, .otherDevice(name: nil))
        XCTAssertEqual(report.usage(forKeyFingerprint: keyD.keyFingerprint)?.origin, .unknownDevice)
        XCTAssertEqual(report.usage(forKeyFingerprint: keyE.keyFingerprint)?.origin, .unrecorded)
    }

    func testNoMultiDeviceStateMeansUnrecorded() {
        let report = KeyMediaAssociationUtil.report(keys: [keyA], albums: [],
                                                    multiDeviceState: nil, currentDeviceID: "this-device",
                                                    mediaCount: { _ in 0 })

        XCTAssertEqual(report.keys.first?.origin, .unrecorded)
    }
}
