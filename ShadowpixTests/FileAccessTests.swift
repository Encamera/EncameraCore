//
//  FileAccessTests.swift
//  ShadowpixTests
//
//  Created by Alexander Freas on 22.06.22.
//

import Foundation
import XCTest
import Sodium
@testable import Shadowpix

class FileAccessTests: XCTestCase {
    
    
    private var directoryModel = DemoDirectoryModel()
    private var imageKey: ImageKey!
    private var fileHandler: FileAccess!
    
    override func setUp() async throws {
        try directoryModel.deleteAllFiles()
        let key = Sodium().secretStream.xchacha20poly1305.key()
        imageKey = ImageKey(name: "testSuite", keyBytes: key, creationDate: Date())
        fileHandler = DiskFileAccess<DemoDirectoryModel>(key: imageKey)
        try FileUtils.tempFilesManager.cleanup()
    }
    
    
    func testSaveNewMedia() async throws {
        
        let movieFile = try FileUtils.createNewMovieFile()
        let encrypted = try await fileHandler.save(media: movieFile)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.source.path))
        
    }
    
    func testTempFilesAreCleanedUpAfterSave() async throws {
        let movieFile = try FileUtils.createNewMovieFile()
        try await fileHandler.save(media: movieFile)
                
        XCTAssertFalse(FileManager.default.fileExists(atPath: movieFile.source.path))
    }
    
    
    func testThumbnailCreated() async throws {
        let movieFile = try FileUtils.createNewMovieFile()
        let encrypted = try await fileHandler.save(media: movieFile)
        
        let thumbURL = directoryModel.thumbnailURLForMedia(encrypted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbURL.path))
        
        _ = try await fileHandler.loadMediaPreview(for: encrypted)
    }
    
    func testLivePhotoMovieAndStillAreSaved() async throws {
        let movieFile = try FileUtils.createNewMovieFile()
        let imageFile = try FileUtils.createNewDataImageMedia(id: movieFile.id)
        
        
        let encryptedMovie = try await fileHandler.save(media: movieFile)
        let encryptedImage = try await fileHandler.save(media: imageFile)
        
        let movieThumbURL = directoryModel.thumbnailURLForMedia(encryptedMovie)
        let imageThumbURL = directoryModel.thumbnailURLForMedia(encryptedImage)
        
        _ = try await fileHandler.loadMediaPreview(for: encryptedMovie)
        _ = try await fileHandler.loadMediaPreview(for: encryptedImage)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: movieThumbURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageThumbURL.path))
        XCTAssertNotEqual(movieThumbURL, imageThumbURL)

    }
    
    func testPreviewObjectIsSaved() async throws {
        let movieFile = try FileUtils.createNewMovieFile()
        let encrypted = try await fileHandler.save(media: movieFile)

        let preview = try await fileHandler.loadMediaPreview(for: encrypted)
        XCTAssertEqual(preview.videoDuration, "0:02")
    }
    
}
