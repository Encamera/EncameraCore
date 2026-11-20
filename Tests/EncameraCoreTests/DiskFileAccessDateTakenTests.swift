//
//  DiskFileAccessDateTakenTests.swift
//  EncameraCoreTests
//
//  A local file's "Date Taken" is its capture date, or the date it was added
//  (its encryption date) when the capture date is unknown.
//

import XCTest
@testable import EncameraCore

final class DiskFileAccessDateTakenTests: XCTestCase {

    private let taken = Date(timeIntervalSince1970: 1_500_000_000)
    private let added = Date(timeIntervalSince1970: 1_700_000_000)
    private let key = PrivateKey(keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskFileAccessDateTakenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// An ENC2 photo whose embedded metadata carries the given dates.
    private func encryptedPhoto(id: String, captureDate: Date?, encryptionDate: Date?) async throws -> URL {
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = captureDate
        metadata.encryptionDate = encryptionDate
        let source = CleartextMedia(source: Data((0..<4096).map { UInt8($0 % 251) }), mediaType: .photo, id: id)
        let url = tempDirectory.appendingPathComponent("\(id).\(MediaType.photo.encryptedFileExtension)")
        _ = try await SecretFileHandlerV2(keyBytes: key.keyBytes, source: source, targetURL: url)
            .encryptWithMetadata(metadata)
        return url
    }

    private func readDates(of url: URL, id: String) async -> MediaWithMetadata<EncryptedMedia>? {
        await DiskFileAccess(key: key)
            .encryptedMediaWithMetadata(for: [EncryptedMedia(source: .url(url), mediaType: .photo, id: id)])
            .first
    }

    func testLocalDateTakenFallsBackToDateAdded() async throws {
        let url = try await encryptedPhoto(id: "a", captureDate: nil, encryptionDate: added)
        let read = await readDates(of: url, id: "a")
        XCTAssertEqual(read?.dateTaken, added)
        XCTAssertEqual(read?.dateEncrypted, added)
    }

    func testLocalDateTakenIsTheCaptureDateWhenKnown() async throws {
        let url = try await encryptedPhoto(id: "a", captureDate: taken, encryptionDate: added)
        let read = await readDates(of: url, id: "a")
        XCTAssertEqual(read?.dateTaken, taken)
        XCTAssertEqual(read?.dateEncrypted, added)
    }
}
