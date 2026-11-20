//
//  CloudKitRecordMetadataHandlerTests.swift
//  EncameraCoreTests
//
//  Encrypting an item's metadata for the `EncMedia.encMetadata` field: what
//  reads back, what does not, and the committed vector that pins the format.
//

import CoreMedia
import XCTest
@testable import EncameraCore

final class CloudKitRecordMetadataHandlerTests: XCTestCase {

    private let key: [UInt8] = Array(repeating: 0x42, count: 32)
    private let recordName = "media-1#0"

    private func fullyPopulatedMetadata() -> EncryptedFileMetadata {
        var metadata = EncryptedFileMetadata()
        metadata.schemaVersion = 1
        metadata.captureDate = Date(timeIntervalSince1970: 1_500_000_000)
        metadata.encryptionDate = Date(timeIntervalSince1970: 1_700_000_000)
        metadata.modificationDate = Date(timeIntervalSince1970: 1_600_000_000)
        metadata.location = .init(latitude: 52.52, longitude: 13.405, altitude: 34.5,
                                  horizontalAccuracy: 5, verticalAccuracy: 3,
                                  timestamp: Date(timeIntervalSince1970: 1_500_000_001),
                                  placeName: "Alexanderplatz", locality: "Berlin",
                                  administrativeArea: "Berlin", country: "Germany", isoCountryCode: "DE")
        metadata.camera = .init(deviceMake: "Apple", deviceModel: "iPhone 15 Pro", aperture: 1.78,
                                shutterSpeed: "1/120", exposureTime: 1.0 / 120, iso: 64,
                                focalLength: 6.86, focalLength35mm: 24, lensModel: "back camera",
                                flashFired: false, flashMode: "auto", orientation: 6, software: "17.0")
        metadata.dimensions = .init(width: 4032, height: 3024, pixelDensity: 72)
        let ramp = SlowMotionRamp(segments: [
            .init(sourceStart: CMTime(value: 600, timescale: 600),
                  sourceDuration: CMTime(value: 1200, timescale: 600),
                  targetDuration: CMTime(value: 9600, timescale: 600))
        ])
        metadata.video = .init(duration: 18.5, frameRate: 240, bitRate: 40_000_000, codec: "hvc1",
                               hasAudio: true, audioCodec: "aac", slowMotion: ramp)
        metadata.originalMediaType = "video"
        metadata.originalExtension = "mov"
        metadata.originalFilename = "IMG_0001.MOV"
        metadata.mimeType = "video/quicktime"
        metadata.originalFileSize = 123_456_789
        metadata.sourceAssetIdentifier = "ABC-123/L0/001"
        metadata.contentAnalysis = .init(dominantColors: ["#112233"], brightness: 0.5, isScreenshot: false,
                                         isLivePhoto: false, isBurst: true, burstIdentifier: "burst-1",
                                         facesDetected: 2)
        metadata.tags = ["trip", "slomo"]
        metadata.customFields = ["k": "v"]
        return metadata
    }

    func testEncryptReadRoundTripPreservesEveryField() throws {
        let metadata = fullyPopulatedMetadata()
        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(metadata, recordName: recordName, keyBytes: key)
        XCTAssertEqual(CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: recordName, keyBytes: key), metadata)
    }

    func testSealedBytesCarryNoPlaintext() throws {
        let metadata = fullyPopulatedMetadata()
        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(metadata, recordName: recordName, keyBytes: key)
        XCTAssertNil(sealed.range(of: Data("Alexanderplatz".utf8)))
        XCTAssertNil(sealed.range(of: Data("IMG_0001".utf8)))
    }

    func testReadMetadataWithWrongKeyReturnsNil() throws {
        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(fullyPopulatedMetadata(), recordName: recordName, keyBytes: key)
        XCTAssertNil(CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: recordName,
                                                                keyBytes: Array(repeating: 0x43, count: 32)))
    }

    func testReadMetadataUnderAnotherRecordNameReturnsNil() throws {
        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(fullyPopulatedMetadata(), recordName: recordName, keyBytes: key)
        XCTAssertNil(CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: "media-1#1", keyBytes: key))
        XCTAssertNil(CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: "", keyBytes: key))
    }

    func testReadMetadataOfTruncatedOrEmptyDataReturnsNil() throws {
        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(fullyPopulatedMetadata(), recordName: recordName, keyBytes: key)
        XCTAssertNil(CloudKitRecordMetadataHandler.readMetadata(Data(), recordName: recordName, keyBytes: key))
        XCTAssertNil(CloudKitRecordMetadataHandler.readMetadata(sealed.prefix(23), recordName: recordName, keyBytes: key))
        XCTAssertNil(CloudKitRecordMetadataHandler.readMetadata(sealed.prefix(24 + 15), recordName: recordName, keyBytes: key))
        XCTAssertNil(CloudKitRecordMetadataHandler.readMetadata(sealed.dropLast(), recordName: recordName, keyBytes: key))
    }

    func testGoldenVectorReads() throws {
        let vector = CloudKitRecordMetadataHandlerGoldenVector.self
        let sealed = try XCTUnwrap(Self.data(fromHex: vector.sealedHex))
        XCTAssertEqual(Array(sealed.prefix(24)), vector.nonce)

        var expected = EncryptedFileMetadata()
        expected.schemaVersion = 1
        expected.captureDate = Date(timeIntervalSince1970: 1_500_000_000)
        expected.location = .init(latitude: 52.52, longitude: 13.405)
        expected.originalMediaType = "photo"

        XCTAssertEqual(CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: vector.recordName, keyBytes: vector.key), expected)
    }

    private static func data(fromHex hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }
}
