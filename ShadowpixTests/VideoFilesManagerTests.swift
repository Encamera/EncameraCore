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

class VideoFilesManagerTests: XCTestCase {
    
    var cancellables: [AnyCancellable] = []
    
    func testEncryptVideo() throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mov")!
//        let sourceUrl = TempFilesManager().createTemporaryMovieUrl()
//        try FileManager.default.copyItem(at: url, to: sourceUrl)
        let destinationUrl = TempFilesManager().createTemporaryMovieUrl()
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let handler = SecretDiskFileHandler(keyBytes: key, source: CleartextMedia(source: sourceUrl), destinationURL: destinationUrl)
        let expectation = expectation(description: "video")
        handler.encryptFile().sink { completion in
            switch completion {
                
            case .finished:
                return
            case .failure(_):
                XCTFail()
                expectation.fulfill()
            }
        } receiveValue: { media in
            XCTAssertTrue(FileManager.default.fileExists(atPath: media.source.path))
            expectation.fulfill()
        }.store(in: &cancellables)

        
        waitForExpectations(timeout: 10)
    }
    
    func testDecryptVideo() throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mov")!
        let destinationUrl = TempFilesManager().createTemporaryMovieUrl()
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let handler = SecretDiskFileHandler(keyBytes: key, source: EncryptedMedia(source: sourceUrl), destinationURL: destinationUrl)
        let encryptExpectation = expectation(description: "encrypt video")
        var encryptedMedia: EncryptedMedia?
        handler.encryptFile().sink { completion in
            
        } receiveValue: { url in
            encryptedMedia = url
            encryptExpectation.fulfill()
        }.store(in: &cancellables)

        waitForExpectations(timeout: 10)

        let unwrappedDecryptedMedia = try XCTUnwrap(encryptedMedia)
        print(unwrappedDecryptedMedia)
        let decryptExpectation = expectation(description: "decrypt video")
        
        let cleartextDestination = TempFilesManager().createTemporaryMovieUrl()
        let decryptHandler = SecretDiskFileHandler(keyBytes: key, source: unwrappedDecryptedMedia, destinationURL: cleartextDestination)
        decryptHandler.decryptFile().sink { completion in
            switch completion {
                
            case .finished:
                return
            case .failure(_):
                XCTFail()
                decryptExpectation.fulfill()
            }
            
        } receiveValue: { media in
            let decryptedURL = try! XCTUnwrap(media.source)
            XCTAssertTrue(FileManager.default.fileExists(atPath: decryptedURL.path))
            print("decrypted file:", decryptedURL)
            decryptExpectation.fulfill()
        }.store(in: &cancellables)

        waitForExpectations(timeout: 10)
        
    }
    
}
