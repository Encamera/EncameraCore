import XCTest
@testable import EncameraCore

final class DiskFileAccessTests: XCTestCase {
    func testTotalStoredMediaCountCountsNormalPhoto() async throws {
        let fileManager = FileManager.default
        let testRoot = LocalStorageModel.rootURL
            .appendingPathComponent("EncameraCoreTests")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let diskAccess = DiskFileAccess()
        let baseline = await diskAccess.totalStoredMediaCount()

        let photoID = UUID().uuidString
        let photoURL = testRoot.appendingPathComponent("\(photoID).\(MediaType.photo.encryptedFileExtension)")
        XCTAssertTrue(fileManager.createFile(atPath: photoURL.path, contents: Data()))

        let after = await diskAccess.totalStoredMediaCount()
        XCTAssertEqual(after - baseline, 1)
    }

    func testTotalStoredMediaCountCountsLivePhotoOnce() async throws {
        let fileManager = FileManager.default
        let testRoot = LocalStorageModel.rootURL
            .appendingPathComponent("EncameraCoreTests")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let diskAccess = DiskFileAccess()
        let baseline = await diskAccess.totalStoredMediaCount()

        let liveID = UUID().uuidString
        let photoURL = testRoot.appendingPathComponent("\(liveID).\(MediaType.photo.encryptedFileExtension)")
        let videoURL = testRoot.appendingPathComponent("\(liveID).\(MediaType.video.encryptedFileExtension)")
        XCTAssertTrue(fileManager.createFile(atPath: photoURL.path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(atPath: videoURL.path, contents: Data()))

        let after = await diskAccess.totalStoredMediaCount()
        XCTAssertEqual(after - baseline, 1)
    }
}
