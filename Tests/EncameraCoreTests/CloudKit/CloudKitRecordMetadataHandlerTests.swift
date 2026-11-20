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

    // MARK: - The record field

    func testDescriptorRoundTripsEncMetadataAndDecodesWithoutIt() throws {
        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(fullyPopulatedMetadata(), recordName: recordName, keyBytes: key)
        let descriptor = CloudKitMediaRecordDescriptor(albumID: "a1", mediaID: "media-1", recordName: recordName,
                                                       mediaType: .video, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                                       sizeBytes: 9, keyFingerprint: "abc", encMetadata: sealed)
        let decoded = try JSONDecoder().decode(CloudKitMediaRecordDescriptor.self,
                                               from: JSONEncoder().encode(descriptor))
        XCTAssertEqual(decoded, descriptor)
        XCTAssertEqual(decoded.encMetadata, sealed)

        let withoutField = CloudKitMediaRecordDescriptor(albumID: "a1", mediaID: "m1", recordName: "m1#0",
                                                         mediaType: .photo, createdAt: Date(),
                                                         sizeBytes: 1, keyFingerprint: "abc")
        let encodedKeys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(withoutField)) as? [String: Any]).keys
        XCTAssertFalse(encodedKeys.contains("encMetadata"), "A descriptor without metadata writes the key set older builds read")

        let older = """
        {"albumID":"a1","mediaID":"m1","recordName":"m1#0","mediaTypeRawValue":0,\
        "createdAt":0,"sizeBytes":1,"keyFingerprint":"abc"}
        """
        let olderDecoded = try JSONDecoder().decode(CloudKitMediaRecordDescriptor.self, from: Data(older.utf8))
        XCTAssertNil(olderDecoded.encMetadata)
        XCTAssertEqual(olderDecoded, CloudKitMediaRecordDescriptor(albumID: "a1", mediaID: "m1", recordName: "m1#0",
                                                                   mediaType: .photo,
                                                                   createdAt: Date(timeIntervalSinceReferenceDate: 0),
                                                                   sizeBytes: 1, keyFingerprint: "abc"))
    }

    /// A queue manifest written before the field existed: its entry loads, rebuilds
    /// and uploads, and the record carries no `encMetadata`.
    func testUploadQueuedWithoutEncMetadataStillDecodesAndUploads() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitRecordMetadataHandlerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: baseDir) }
        let albumDir = baseDir.appendingPathComponent(CloudKitBlobCache.albumFolderName("a1"), isDirectory: true)
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)
        try Data("ciphertext".utf8).write(to: albumDir.appendingPathComponent("m1_0.photo"))
        let manifest = """
        [{"albumID":"a1","mediaID":"m1","recordName":"m1#0","mediaTypeRawValue":0,\
        "createdAt":0,"sizeBytes":10,"fileName":"m1_0.photo","keyFingerprint":"abc",\
        "queuedAt":5,"attempts":0,"hasGivenUp":false}]
        """
        try Data(manifest.utf8).write(to: baseDir.appendingPathComponent("queue.json"))

        let queue = CloudKitUploadQueue(baseDir: baseDir)
        let pending = await queue.pendingItem(recordName: "m1#0")
        let item = try XCTUnwrap(pending, "The entry must decode from the older manifest")
        XCTAssertNil(item.encMetadata)

        let store = InMemoryCloudKitMediaStore()
        let upload = await queue.rebuild(item, thumbURL: nil)
        _ = try await store.upload(upload, progress: { _ in })
        let fetched = try await store.fetchRecordMetadata(recordName: "m1#0")
        let uploaded = try XCTUnwrap(fetched)
        XCTAssertEqual(uploaded.albumID, "a1")
        XCTAssertEqual(uploaded.keyFingerprint, "abc")
        XCTAssertNil(uploaded.encMetadata)
    }

    func testReassignKeepsEncMetadata() async throws {
        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(fullyPopulatedMetadata(), recordName: recordName, keyBytes: key)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString)")
        try Data("ciphertext".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let store = InMemoryCloudKitMediaStore()
        let descriptor = CloudKitMediaRecordDescriptor(albumID: "source", mediaID: "media-1", recordName: recordName,
                                                       mediaType: .photo, createdAt: Date(),
                                                       sizeBytes: 10, keyFingerprint: "abc", encMetadata: sealed)
        _ = try await store.upload(CloudKitMediaUpload(descriptor: descriptor, encryptedFileURL: file, encryptedThumbURL: nil),
                                   progress: { _ in })

        let notFound = try await store.reassignAlbum(recordNames: [recordName], toAlbumID: "destination")
        XCTAssertEqual(notFound, [])
        let fetched = try await store.fetchRecordMetadata(recordName: recordName)
        let moved = try XCTUnwrap(fetched)
        XCTAssertEqual(moved.albumID, "destination")
        XCTAssertEqual(moved.encMetadata, sealed)
        XCTAssertEqual(CloudKitRecordMetadataHandler.readMetadata(try XCTUnwrap(moved.encMetadata), recordName: recordName, keyBytes: key),
                       fullyPopulatedMetadata())
    }

    func testMetadataKeysIncludeEncMetadataAndExcludeBlob() {
        XCTAssertTrue(CloudKitMediaStore.metadataKeys.contains(CloudKitSchema.EncMedia.encMetadata))
        XCTAssertTrue(CloudKitMediaStore.changeFeedKeys.contains(CloudKitSchema.EncMedia.encMetadata))
        XCTAssertFalse(CloudKitMediaStore.metadataKeys.contains(CloudKitSchema.EncMedia.encBlob))
        XCTAssertFalse(CloudKitMediaStore.changeFeedKeys.contains(CloudKitSchema.EncMedia.encBlob))
    }

    // MARK: - Records a save creates

    /// Metadata with values a log line could leak, kept short of the fields a
    /// save derives itself.
    private func capturedMetadata(originalMediaType: String) -> EncryptedFileMetadata {
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = Date(timeIntervalSince1970: 1_500_000_000)
        metadata.encryptionDate = Date(timeIntervalSince1970: 1_700_000_000)
        metadata.location = .init(latitude: 52.52, longitude: 13.405, placeName: "Alexanderplatz")
        metadata.originalMediaType = originalMediaType
        metadata.originalFilename = "IMG_SECRET_0001.HEIC"
        return metadata
    }

    /// A CloudKit album under `key`, and an access that saves into `store`.
    private func makeSavingAccess(store: InMemoryCloudKitMediaStore) async -> (CloudKitFileAccess, Album) {
        let album = Album(name: "record-metadata-\(UUID().uuidString)", storageOption: .cloudKit, creationDate: Date(),
                          key: PrivateKey(keyBytes: key, creationDate: Date()), albumID: UUID().uuidString)
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [album]
        let access = await CloudKitFileAccess(album: album, albumManager: albumManager, store: store)
        let albumBaseURL = CloudKitStorageModel(album: album).baseURL
        let indexURL = MediaIndexStore.indexURL(for: album)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: albumBaseURL)
            try? FileManager.default.removeItem(at: indexURL)
        }
        return (access, album)
    }

    private func removePreviewAfterTest(mediaID: String) {
        addTeardownBlock { try? FileManager.default.removeItem(at: CloudKitStorageModel.previewURL(forMediaID: mediaID)) }
    }

    /// The metadata the record's `encMetadata` opens to under `keyBytes`, or nil.
    private func openedRecordMetadata(in store: CloudKitMediaStoring,
                                      recordName: String,
                                      keyBytes: [UInt8]) async throws -> EncryptedFileMetadata? {
        let fetched = try await store.fetchRecordMetadata(recordName: recordName)
        let record = try XCTUnwrap(fetched, "no record named \(recordName)")
        let sealed = try XCTUnwrap(record.encMetadata, "record \(recordName) carries no encMetadata")
        return CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: recordName, keyBytes: keyBytes)
    }

    /// The metadata encrypted into the record's blob.
    private func blobMetadata(in store: CloudKitMediaStoring,
                              recordName: String,
                              keyBytes: [UInt8]) async throws -> EncryptedFileMetadata? {
        let blobURL = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blobURL) }
        try await store.fetchBlob(recordName: recordName, to: blobURL, progress: { _ in })
        return try await EncryptedMetadataHandler().readMetadata(from: blobURL, keyBytes: keyBytes)
    }

    func testSaveSingleWritesEncMetadataThatOpensToTheSavedMetadata() async throws {
        let store = InMemoryCloudKitMediaStore()
        let (access, _) = await makeSavingAccess(store: store)

        let photoID = UUID().uuidString
        removePreviewAfterTest(mediaID: photoID)
        let photoMetadata = capturedMetadata(originalMediaType: "photo")
        let photo = try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: photoID)
        ])
        _ = try await access.save(media: photo, metadata: photoMetadata, progress: { _ in })

        let movieURL = FileManager.default.temporaryDirectory.appendingPathComponent("record-metadata-\(UUID().uuidString).mov")
        try await EncryptedStreamResourceLoaderTests.writeTinyMovie(to: movieURL, seconds: 1)
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let videoID = UUID().uuidString
        removePreviewAfterTest(mediaID: videoID)
        var videoMetadata = capturedMetadata(originalMediaType: "video")
        videoMetadata.video = .init(duration: 1, frameRate: 30, codec: "avc1", hasAudio: false)
        let video = try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .url(movieURL), mediaType: .video, id: videoID)
        ])
        _ = try await access.save(media: video, metadata: videoMetadata, progress: { _ in })
        await access.drainUploads()

        for (id, type, saved) in [(photoID, MediaType.photo, photoMetadata), (videoID, .video, videoMetadata)] {
            let recordName = MediaRecordName.componentRecordName(mediaID: id, type: type)
            let opened = try await openedRecordMetadata(in: store, recordName: recordName, keyBytes: key)
            XCTAssertEqual(opened, saved, "the \(type) record opens to the metadata it was saved with")
            let inFile = try await blobMetadata(in: store, recordName: recordName, keyBytes: key)
            XCTAssertEqual(opened, inFile, "the \(type) record and its file carry the same metadata")
        }
    }

    func testSaveWithoutMetadataSealsTheEmptyMetadataItsFileCarries() async throws {
        let store = InMemoryCloudKitMediaStore()
        let (access, _) = await makeSavingAccess(store: store)
        let id = UUID().uuidString
        removePreviewAfterTest(mediaID: id)
        let photo = try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: id)
        ])

        _ = try await access.save(media: photo, metadata: nil, progress: { _ in })
        await access.drainUploads()

        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .photo)
        let opened = try await openedRecordMetadata(in: store, recordName: recordName, keyBytes: key)
        XCTAssertEqual(opened, EncryptedFileMetadata())
        let inFile = try await blobMetadata(in: store, recordName: recordName, keyBytes: key)
        XCTAssertEqual(opened, inFile)
    }

    func testLivePhotoComponentsBothCarryEncMetadata() async throws {
        let store = InMemoryCloudKitMediaStore()
        let (access, _) = await makeSavingAccess(store: store)
        let id = UUID().uuidString
        removePreviewAfterTest(mediaID: id)
        var metadata = capturedMetadata(originalMediaType: "livePhoto")
        metadata.contentAnalysis = .init(isLivePhoto: true)
        let live = try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: id),
            CleartextMedia(source: .data(Data("live photo video".utf8)), mediaType: .video, id: id),
        ])
        XCTAssertEqual(live.mediaType, .livePhoto)

        _ = try await access.save(media: live, metadata: metadata, progress: { _ in })
        await access.drainUploads()

        for type in [MediaType.photo, .video] {
            let recordName = MediaRecordName.componentRecordName(mediaID: id, type: type)
            let opened = try await openedRecordMetadata(in: store, recordName: recordName, keyBytes: key)
            XCTAssertEqual(opened, metadata, "the Live Photo's \(type) record carries its metadata")
        }
    }

    func testSaveLogNamesTheRecordWithoutMetadataValues() async throws {
        let wasCapturing = DebugLogBuffer.shared.isCapturing
        DebugLogBuffer.shared.setCapturing(true)
        DebugLogBuffer.shared.clear()
        defer { DebugLogBuffer.shared.setCapturing(wasCapturing) }
        let store = InMemoryCloudKitMediaStore()
        let (access, _) = await makeSavingAccess(store: store)
        let id = UUID().uuidString
        removePreviewAfterTest(mediaID: id)
        let metadata = capturedMetadata(originalMediaType: "photo")
        let photo = try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: id)
        ])

        _ = try await access.save(media: photo, metadata: metadata, progress: { _ in })
        await access.drainUploads()

        let lines = DebugLogBuffer.shared.snapshot(newestFirst: false).map(\.message)
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .photo)
        XCTAssertTrue(lines.contains { $0.contains(recordName) }, "the upload log names the record")
        assertNoLine(lines, leaks: metadata)
    }

    private func assertNoLine(_ lines: [String], leaks metadata: EncryptedFileMetadata,
                              file: StaticString = #filePath, line: UInt = #line) {
        let values = [metadata.location?.placeName, metadata.originalFilename,
                      metadata.captureDate.map { "\($0)" }, metadata.encryptionDate.map { "\($0)" },
                      metadata.location.map { "\($0.latitude)" }].compactMap { $0 }
        for value in values {
            XCTAssertFalse(lines.contains { $0.contains(value) }, "a log line carries the metadata value \(value)",
                           file: file, line: line)
        }
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
