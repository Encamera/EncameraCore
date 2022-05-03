//
//  VideoFilesManagerTests.swift
//  ShadowpixTests
//
//  Created by Alexander Freas on 02.05.22.
//

import Foundation
import XCTest
import Sodium
@testable import Shadowpix

class VideoFilesManagerTests: XCTestCase {
    
    func testEncryptVideo() throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mov")!
//        let sourceUrl = TempFilesManager().createTemporaryMovieUrl()
//        try FileManager.default.copyItem(at: url, to: sourceUrl)
        let destinationUrl = TempFilesManager().createTemporaryMovieUrl()
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let handler = VideoFileProcessor(sourceURL: sourceUrl, destinationURL: destinationUrl, key: key)
        let expectation = expectation(description: "video")
        handler.encryptVideo { (url, error) in
            XCTAssertNil(error)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10)
    }
    
    func testDecryptVideo() throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mov")!
        let destinationUrl = TempFilesManager().createTemporaryMovieUrl()
        let key = Sodium().secretStream.xchacha20poly1305.key()
        let handler = VideoFileProcessor(sourceURL: sourceUrl, destinationURL: destinationUrl, key: key)
        let encryptExpectation = expectation(description: "encrypt video")
        var encryptedURL: URL?
        handler.encryptVideo { (url, error) in
            XCTAssertNil(error)
            encryptedURL = url
            encryptExpectation.fulfill()
        }
        waitForExpectations(timeout: 10)

        let unwrappedURL = try XCTUnwrap(encryptedURL)
        print(unwrappedURL)
        let decryptExpectation = expectation(description: "decrypt video")
        
        let unencryptedDestination = TempFilesManager().createTemporaryMovieUrl()
        let decryptHandler = VideoFileProcessor(sourceURL: unwrappedURL, destinationURL: unencryptedDestination, key: key)
        decryptHandler.decryptVideo { (url, error) in
            print("decrypted file:", url!)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
            decryptExpectation.fulfill()
        }

        waitForExpectations(timeout: 10)
        
    }
    
}
