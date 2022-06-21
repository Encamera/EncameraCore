//
//  VideoFilesManagerTests.swift
//  ShadowpixTests
//
//  Created by Alexander Freas on 02.05.22.
//

import Foundation
import XCTest
import Sodium
import Combine
@testable import Shadowpix

class FileOperationsTests: XCTestCase {
    
    var cancellables: [AnyCancellable] = []
    let tempFiles = TempFilesManager()

    override func setUp() {
        
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        do {
            print("Directory \(documentsDirectory.absoluteString)")
            guard FileManager.default.fileExists(atPath: documentsDirectory.path) else {
                return
            }
            let enumerator = try FileManager.default.contentsOfDirectory(atPath: documentsDirectory.path)
            for path in enumerator {
                print("Removing item at \(path)")
                try FileManager.default.removeItem(atPath: documentsDirectory.appendingPathComponent(path).path)
                print("Removed item at \(path)")
            }
        } catch {
            XCTFail("Error clearing dir \(error)")
            fatalError()
        }
    }
    
    func testEncryptInMemory() async throws {
        let sourceMedia = try createNewDataImageMedia()
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia)
        
        let encrypted = try await handler.encrypt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))

    }
    
    func testEncryptVideo() async throws {
        
        
        let sourceMedia = try createNewMovieFile()
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia)
        let encrypted = try await handler.encrypt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
    }
    
    func testDecryptVideo() async throws {
        
        let sourceMedia = try createNewMovieFile()
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia)
        let encrypted = try await handler.encrypt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
        let decryptHandler = SecretFileHandler(keyBytes: key, source: encrypted)
        let decrypted: CleartextMedia<URL> = try await decryptHandler.decrypt()
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: decrypted.source.path))
    }
    
    func testCreateThumbnail() throws {
        
    }
    
    func testDriveURLIsCorrectForThumbnail() throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        
        
        let media = try XCTUnwrap(EncryptedMedia(source: sourceUrl))
        
        let directory = iCloudFilesDirectoryModel(keyName: "test")
        let url = try directory.thumbnailURLForMedia(media)
        
        let components = Array(url.absoluteString.split(separator: "/").reversed())
        XCTAssertEqual("image.thumb", components[0])
        XCTAssertEqual("thumbs", components[1])
        XCTAssertEqual("Documents", components[2])
    }
    
    func testCreatePhotoThumbnailAndSave() async throws {

        let key = Sodium().secretStream.xchacha20poly1305.key()
        let imageKey = ImageKey(name: "test", keyBytes: key)
        let fileAccess = DiskFileAccess<DemoDirectoryModel>(key: imageKey)
        
        let sourceMedia = try createNewImageMedia()
        let encrypted = try await fileAccess.save(media: sourceMedia)

        let thumbnail = try await fileAccess.loadMediaPreview(for: encrypted)
        
        let thumbnailPath = try DemoDirectoryModel().thumbnailURLForMedia(encrypted)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailPath.path))

        
        print(thumbnail)
    }
    
    func testCreateVideoThumbnailAndSave() async throws {
        let sourceMedia = try createNewMovieFile()
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let imageKey = ImageKey(name: "testMov", keyBytes: key)

        print("xxxx sourcemedia \(sourceMedia.source)")
        let fileAccess = DiskFileAccess<DemoDirectoryModel>(key: imageKey)
        
        
        let encrypted = try await fileAccess.save(media: sourceMedia)

        let thumbnail = try await fileAccess.loadMediaPreview(for: encrypted)
        
        let thumbnailPath = try DemoDirectoryModel().thumbnailURLForMedia(encrypted)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailPath.path))

        
        print(thumbnail)
    }
    
    private func createNewMovieFile() throws -> CleartextMedia<URL> {
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mov")!

        let directoryModel = DemoDirectoryModel()
        try directoryModel.initializeDirectories()
        let cleartext = CleartextMedia(source: sourceUrl, mediaType: .video, id: NSUUID().uuidString)
        let tempURL = directoryModel.driveURLForNewMedia(cleartext).deletingPathExtension()
        try! FileManager.default.copyItem(at: sourceUrl, to: tempURL)
        let sourceMedia = CleartextMedia(source: tempURL)

        return sourceMedia
    }
    
    private func createNewImageMedia() throws -> CleartextMedia<URL> {
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        let directoryModel = DemoDirectoryModel()
        try directoryModel.initializeDirectories()
        let cleartext = CleartextMedia(source: sourceUrl, mediaType: .photo, id: NSUUID().uuidString)
        let tempURL = directoryModel.driveURLForNewMedia(cleartext).deletingPathExtension()
        try! FileManager.default.copyItem(at: sourceUrl, to: tempURL)
        let sourceMedia = CleartextMedia(source: tempURL)

        return sourceMedia

    }
    
    
    private func createNewDataImageMedia() throws -> CleartextMedia<Data> {
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        let sourceData = try Data(contentsOf: sourceUrl)
        let sourceMedia = CleartextMedia(source: sourceData)
        return sourceMedia
    }
    
}
