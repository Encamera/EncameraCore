//
//  MediaTypeTests.swift
//  ShadowpixTests
//
//  Created by Alexander Freas on 03.06.22.
//

import Foundation
import XCTest
@testable import Shadowpix

class MediaTypeTests: XCTestCase {
    
    func testEncryptedTypeDetermination() throws {
        
        let url = try XCTUnwrap(URL(string: "/Users/akfreas/Library/Developer/CoreSimulator/Devices/9D0BD392-4346-463B-883A-4F3B4B844374/data/Containers/Data/Application/3F9755A2-4CE1-4E6C-91F1-C7DE1B652C26/tmp/E78B48A6-503E-473F-832A-A0100979BCD1.mov.shdwpic"))
        
        let encrypted = try XCTUnwrap(EncryptedMedia(source: url))
                
        XCTAssertEqual(encrypted.mediaType, .video)
        
    }
    
    func testCleartextURLTypeDetermination() throws {
        let url = try XCTUnwrap(URL(string: "/Users/akfreas/Library/Developer/CoreSimulator/Devices/9D0BD392-4346-463B-883A-4F3B4B844374/data/Containers/Data/Application/3F9755A2-4CE1-4E6C-91F1-C7DE1B652C26/tmp/E78B48A6-503E-473F-832A-A0100979BCD1.mov"))

        let cleartext = CleartextMedia(source: url)
        
        XCTAssertEqual(cleartext.mediaType, .video)
        
    }
    
    func testCleartextDataTypeDetermination() throws {
        let data = Data()
        
        let cleartext = CleartextMedia(source: data)
        
        XCTAssertEqual(cleartext.mediaType, .photo)
    }
    
}
