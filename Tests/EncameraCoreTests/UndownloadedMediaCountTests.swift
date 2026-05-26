//
//  UndownloadedMediaCountTests.swift
//  EncameraCoreTests
//
//  Regression coverage for the `.icloud` placeholder handling that
//  `undownloadedMediaCount()` relies on. iCloud names placeholder stubs
//  `.<id>.<ext>.icloud`; the enumerator's middle-extension filter is the
//  only thing keeping those URLs in the result set.
//

import XCTest
@testable import EncameraCore

final class UndownloadedMediaCountTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncameraCoreTests-iCloudPlaceholder")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// iCloud placeholders sit on disk as `.<id>.<encext>.icloud` — the leading
    /// dot makes them hidden, and the trailing `.icloud` extension is the
    /// signal. The directory enumerator must return them when callers ask for
    /// the encrypted extensions, because the middle-extension match handles
    /// placeholders explicitly.
    func testEnumeratorIncludesICloudPlaceholders() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloadedID = UUID().uuidString
        let placeholderID = UUID().uuidString
        let downloadedURL = dir.appendingPathComponent("\(downloadedID).encimage")
        let placeholderURL = dir.appendingPathComponent(".\(placeholderID).encimage.icloud")
        XCTAssertTrue(FileManager.default.createFile(atPath: downloadedURL.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: placeholderURL.path, contents: Data()))

        let urls = LocalStorageModel.enumeratorForStorageDirectory(
            at: dir,
            fileExtensionFilter: ["encimage", "encvideo"]
        )

        let names = Set(urls.map { $0.lastPathComponent })
        XCTAssertTrue(names.contains("\(downloadedID).encimage"),
                      "downloaded file should be enumerated")
        XCTAssertTrue(names.contains(".\(placeholderID).encimage.icloud"),
                      "iCloud placeholder should be enumerated despite the .icloud suffix")
    }

    /// `URL.pathExtension` strips the last extension only — for an iCloud
    /// placeholder that's literally "icloud". `undownloadedMediaCount` relies
    /// on this exact contract.
    func testICloudPlaceholderURLHasICloudPathExtension() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID().uuidString
        let placeholderURL = dir.appendingPathComponent(".\(id).encimage.icloud")
        XCTAssertTrue(FileManager.default.createFile(atPath: placeholderURL.path, contents: Data()))

        let urls = LocalStorageModel.enumeratorForStorageDirectory(
            at: dir,
            fileExtensionFilter: ["encimage", "encvideo"]
        )

        guard let enumerated = urls.first(where: { $0.lastPathComponent.hasSuffix(".icloud") }) else {
            return XCTFail("placeholder URL not returned by enumerator")
        }
        XCTAssertEqual(enumerated.pathExtension, "icloud")
    }

    /// `EncryptedMedia(source:.url(...), generateID: false)` must derive the
    /// real media id from a placeholder URL the same way it does for a
    /// downloaded file, so `currentMediaURLsByID()` groups both sides under
    /// the same id.
    func testEncryptedMediaIDIsExtractedFromICloudPlaceholder() {
        let id = UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(".\(id).encimage.icloud")

        let media = EncryptedMedia(source: .url(url), generateID: false)
        XCTAssertNotNil(media)
        XCTAssertEqual(media?.id, id)
    }
}
