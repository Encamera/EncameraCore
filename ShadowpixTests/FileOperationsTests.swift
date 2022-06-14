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
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        let sourceData = try Data(contentsOf: sourceUrl)
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let handler = SecretDiskFileHandler(keyBytes: key, source: CleartextMedia(source: sourceData))
        let encrypted = try await handler.encryptFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))

    }
    
    func testEncryptVideo() async throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mov")!
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let handler = SecretDiskFileHandler(keyBytes: key, source: CleartextMedia(source: sourceUrl))
        let encrypted = try await handler.encryptFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
    }
    
    func testDecryptVideo() async throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mov")!
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let cleartext = try XCTUnwrap(EncryptedMedia(source: sourceUrl))
        let handler = SecretDiskFileHandler(keyBytes: key, source: cleartext)
        let encrypted = try await handler.encryptFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
        let decryptHandler = SecretDiskFileHandler(keyBytes: key, source: encrypted)
        let decrypted = try await decryptHandler.decryptFile()
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: decrypted.source.path))

        
    }
    
    func testCreateThumbnail() throws {
        
    }
    
    func testDriveURLIsCorrectForThumbnail() throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        
        
        let media = try XCTUnwrap(EncryptedMedia(source: sourceUrl))
        
        let directory = DemoDirectoryModel(subdirectory: MediaType.photo.path, keyName: "test")
        let url = try directory.thumbnailURLForMedia(media)
        
        let components = Array(url.absoluteString.split(separator: "/").reversed())
        XCTAssertEqual("image.thumb", components[0])
        XCTAssertEqual("thumbs", components[1])
        XCTAssertEqual("Documents", components[2])
    }
    
    func testCreatePhotoThumbnailAndSave() async throws {
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!

        let key = Sodium().secretStream.xchacha20poly1305.key()
        let imageKey = ImageKey(name: "test", keyBytes: key)
        let fileAccess = DiskFileAccess<DemoDirectoryModel>(key: imageKey)
        
        let sourceMedia = CleartextMedia(source: sourceUrl)
        
        let encrypted = try await fileAccess.save(media: sourceMedia)

        let thumbnail = try await fileAccess.loadMediaPreview(for: encrypted)
        
        let thumbnailPath = try DemoDirectoryModel().thumbnailURLForMedia(encrypted)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailPath.path))

        
        print(thumbnail)
    }
    
    func testCreateVideoThumbnailAndSave() async throws {
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mov")!

        let key = Sodium().secretStream.xchacha20poly1305.key()
        let imageKey = ImageKey(name: "testMov", keyBytes: key)
        let fileAccess = DiskFileAccess<DemoDirectoryModel>(key: imageKey)
        
        let sourceMedia = CleartextMedia(source: sourceUrl)
        
        let encrypted = try await fileAccess.save(media: sourceMedia)

        let thumbnail = try await fileAccess.loadMediaPreview(for: encrypted)
        
        let thumbnailPath = try DemoDirectoryModel().thumbnailURLForMedia(encrypted)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailPath.path))

        
        print(thumbnail)
    }
    
}
