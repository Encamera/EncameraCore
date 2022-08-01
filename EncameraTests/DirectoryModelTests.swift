//
//  DirectoryModelTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on 22.06.22.
//

import Foundation
import XCTest
@testable import Encamera

class DirectoryModelTests: XCTestCase {
    
    func testDriveURLIsCorrectForThumbnail() throws {
        
        let sourceUrl = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        
        
        let media = try XCTUnwrap(EncryptedMedia(source: sourceUrl, mediaType: .photo, id: "imageID"))
        
        let directory = iCloudFilesDirectoryModel(keyName: "test")
        let url = directory.thumbnailURLForMedia(media)
        
        let components = Array(url.absoluteString.split(separator: "/").reversed())
        XCTAssertEqual("imageID.jpg.thmb", components[0])
        XCTAssertEqual("thumbs", components[1])
        XCTAssertEqual("Documents", components[2])
    }
}
