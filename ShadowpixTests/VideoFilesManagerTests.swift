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
        let handler = VideoFileProcessor(key: key, sourceURL: sourceUrl, destinationURL: destinationUrl)
        let expectation = expectation(description: "video")
        handler.encryptVideo().sink { completion in
            switch completion {
                
            case .finished:
                return
            case .failure(_):
                XCTFail()
                expectation.fulfill()
            }
        } receiveValue: { url in
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            expectation.fulfill()
        }.store(in: &cancellables)

        
        waitForExpectations(timeout: 10)
    }
    
    func testDecryptVideo() throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mov")!
        let destinationUrl = TempFilesManager().createTemporaryMovieUrl()
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let handler = VideoFileProcessor(key: key, sourceURL: sourceUrl, destinationURL: destinationUrl)
        let encryptExpectation = expectation(description: "encrypt video")
        var encryptedURL: URL?
        handler.encryptVideo().sink { completion in
            
        } receiveValue: { url in
            encryptedURL = url
            encryptExpectation.fulfill()
        }.store(in: &cancellables)

        waitForExpectations(timeout: 10)

        let unwrappedURL = try XCTUnwrap(encryptedURL)
        print(unwrappedURL)
        let decryptExpectation = expectation(description: "decrypt video")
        
        let unencryptedDestination = TempFilesManager().createTemporaryMovieUrl()
        let decryptHandler = VideoFileProcessor(key: key, sourceURL: unwrappedURL, destinationURL: unencryptedDestination)
        decryptHandler.decryptVideo().sink { completion in
            switch completion {
                
            case .finished:
                return
            case .failure(_):
                XCTFail()
                decryptExpectation.fulfill()
            }
            
        } receiveValue: { url in
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            print("decrypted file:", url)
            decryptExpectation.fulfill()
        }.store(in: &cancellables)

        waitForExpectations(timeout: 10)
        
    }
    
}
