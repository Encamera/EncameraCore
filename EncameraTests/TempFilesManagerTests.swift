//
//  TempFilesManagerTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on 22.06.22.
//

import Foundation
import XCTest
@testable import Encamera

class TempFilesManagerTests: XCTestCase {
    
    private var directoryModel = DemoDirectoryModel()
    
    func testCleanup() throws {
        
        var urls: [URL] = []
        for _ in (0..<5) {
            let cleartext = try FileUtils.createNewImageMedia()
            XCTAssertTrue(FileManager.default.fileExists(atPath: cleartext.source.path))
            urls.append(cleartext.source)
        }
        XCTAssertEqual(5, urls.count)
        
        urls.forEach { url in
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
