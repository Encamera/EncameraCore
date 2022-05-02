//
//  VideoFilesManagerTests.swift
//  ShadowpixTests
//
//  Created by Alexander Freas on 02.05.22.
//

import Foundation
import XCTest
@testable import Shadowpix

class VideoFilesManagerTests: XCTestCase {
    
    func testEncryptVideo() throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mov")!
//        let sourceUrl = TempFilesManager().createTemporaryMovieUrl()
//        try FileManager.default.copyItem(at: url, to: sourceUrl)
        let destinationUrl = TempFilesManager().createTemporaryMovieUrl()
        let handler = VideoFileProcessor(sourceURL: sourceUrl, destinationURL: destinationUrl)
        let expectation = expectation(description: "video")
        handler.encryptVideo { (url, error) in
            XCTAssertNil(error)
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10)
    }
    
    func testDecryptVideo() throws {
        
        
    }
    
}
