//
//  VideoFilesManagerTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on 02.05.22.
//

import Foundation
import XCTest
import Sodium
import Combine
@testable import Encamera

class FileOperationsTests: XCTestCase {
    
    var cancellables: [AnyCancellable] = []
    let tempFiles = TempFilesManager(subdirectory: "FileOperationsTests")
    private var key: Array<UInt8>!

    private let directoryModel = DemoDirectoryModel()

    override func setUp() {
        key = Sodium().secretStream.xchacha20poly1305.key()
        try! tempFiles.cleanup()
    }
    
    func testEncryptInMemory() async throws {
        let sourceMedia = try FileUtils.createNewDataImageMedia()
        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia)
        
        let encrypted = try await handler.encrypt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))

    }
    
    func testEncryptVideo() async throws {
        
        
        let sourceMedia = try FileUtils.createNewMovieFile()

        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia)
        let encrypted = try await handler.encrypt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
    }
    
    func testDecryptVideo() async throws {
        
        let sourceMedia = try FileUtils.createNewMovieFile()

        let handler = SecretFileHandler(keyBytes: key, source: sourceMedia)
        let encrypted = try await handler.encrypt()
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
        let decryptHandler = SecretFileHandler(keyBytes: key, source: encrypted)
        let decrypted: CleartextMedia<URL> = try await decryptHandler.decrypt()
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: decrypted.source.path))
    }
    
}
