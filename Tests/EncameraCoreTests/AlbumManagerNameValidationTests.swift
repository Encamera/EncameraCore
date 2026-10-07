//
//  AlbumManagerNameValidationTests.swift
//  EncameraCoreTests
//
//  `AlbumManager` refuses a name the filesystem would refuse before it
//  touches the keychain or the disk. Every test here expects a throw, so
//  nothing is written to the test host's Documents directory.
//

import XCTest
@testable import EncameraCore

final class AlbumManagerNameValidationTests: XCTestCase {

    private var manager: AlbumManager!

    override func setUp() {
        super.setUp()
        manager = AlbumManager(keyManager: DemoKeyManager())
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    private func album(named name: String) -> Album {
        Album(name: name, storageOption: .local, creationDate: Date(),
              key: PrivateKey(name: "k", keyBytes: [], creationDate: Date()))
    }

    private func assertForbidden(_ expression: @autoclosure () throws -> Any,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? AlbumError, .albumNameForbidden, file: file, line: line)
        }
    }

    func testCreateRefusesDirectoryEntryNames() {
        assertForbidden(try manager.create(name: ".", storageOption: .local))
        assertForbidden(try manager.create(name: "..", storageOption: .icloud))
    }

    func testCreateRefusesPathSeparators() {
        assertForbidden(try manager.create(name: "Trip/2023", storageOption: .local))
        assertForbidden(try manager.create(name: "Trip: Rome", storageOption: .local))
    }

    func testRenameRefusesDirectoryEntryNames() {
        assertForbidden(try manager.renameAlbum(album: album(named: "Trip"), to: "."))
        assertForbidden(try manager.renameAlbum(album: album(named: "Trip"), to: ".."))
    }

    func testRenameRefusesPathSeparators() {
        assertForbidden(try manager.renameAlbum(album: album(named: "Trip"), to: "Trip/2023"))
    }

    /// Only the new name is validated. An album that already carries a name
    /// the validator would refuse — one saved before validation existed — can
    /// still be renamed out of it: the rename gets past the name check and on
    /// to the filesystem, where this test's album does not exist.
    func testRenameValidatesOnlyTheNewName() {
        for oldName in ["Trip: Rome", ".", "", "Trip/2023"] {
            XCTAssertThrowsError(try manager.renameAlbum(album: album(named: oldName), to: "Trip Rome"),
                                 "\(oldName.debugDescription) should reach the filesystem") { error in
                XCTAssertEqual(error as? AlbumError, .albumNotFoundAtSourceLocation,
                               "\(oldName.debugDescription) was refused by name")
            }
        }
    }

    func testValidateAlbumNameReportsForbiddenAndEmptyAsAlbumErrors() {
        assertForbidden(try manager.validateAlbumName(name: "."))
        XCTAssertThrowsError(try manager.validateAlbumName(name: "")) { error in
            XCTAssertEqual(error as? AlbumError, .albumNameError)
        }
        XCTAssertNoThrow(try manager.validateAlbumName(name: "Trip 2.0"))
    }
}
