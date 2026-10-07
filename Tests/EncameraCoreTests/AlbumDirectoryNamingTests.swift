//
//  AlbumDirectoryNamingTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

final class AlbumDirectoryNamingTests: XCTestCase {

    func testEncryptedAndPlaintextAlbumNamesAreAlbums() {
        XCTAssertTrue(AlbumDirectoryNaming.isAlbumDirectoryName("Album_c29tZSBuYW1l"))
        XCTAssertTrue(AlbumDirectoryNaming.isAlbumDirectoryName("Holiday 2019"))
    }

    func testKnownSiblingsAreNotAlbums() {
        XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName("albums"))
        XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName("RevenueCat"))
        XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName(".Trash"))
    }

    func testRevenueCatCachesAreNotAlbums() {
        XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName("me.freas.encamera.revenuecat.etags"),
                       "the SDK's etag cache was adopted as an album on the launch after an erase")
        XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName("me.freas.encamera-debug.RevenueCat.diagnostics"))
    }

    /// A pre-encryption album is named whatever the user typed, and 2.10.0
    /// lists names that start with a dot.
    func testDotPrefixedPlaintextNamesAreAlbums() {
        for name in [".secret", ".2023", ".Trip 2.0", "...", ".photos.from.rome"] {
            XCTAssertTrue(AlbumDirectoryNaming.isAlbumDirectoryName(name), "\(name.debugDescription) should be an album")
        }
    }

    func testDotPrefixedBookkeepingDirectoriesAreNotAlbums() {
        for name in [".Trash", ".trash", ".Trashes", ".fseventsd", ".Spotlight-V100",
                     ".DocumentRevisions-V100", ".TemporaryItems",
                     ".com.apple.bookkeeping", ".me.freas.encamera.revenuecat.etags", ".RevenueCat"] {
            XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName(name), "\(name.debugDescription) should not be an album")
        }
    }
}
