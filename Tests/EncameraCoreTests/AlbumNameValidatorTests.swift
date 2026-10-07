//
//  AlbumNameValidatorTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

final class AlbumNameValidatorTests: XCTestCase {

    func testRejectsEmptyAndWhitespaceOnlyNames() {
        XCTAssertEqual(AlbumNameValidator.violation(in: ""), .empty)
        XCTAssertEqual(AlbumNameValidator.violation(in: "   "), .empty)
        XCTAssertEqual(AlbumNameValidator.violation(in: "\n"), .empty)
    }

    /// `.` and `..` are directory entries on every filesystem, never names a
    /// directory can be given.
    func testRejectsCurrentAndParentDirectoryNames() {
        XCTAssertEqual(AlbumNameValidator.violation(in: "."), .reservedName)
        XCTAssertEqual(AlbumNameValidator.violation(in: ".."), .reservedName)
    }

    /// `/` is the POSIX path separator, `:` the HFS one that Finder and iCloud
    /// Drive still refuse, and control characters have no place in a name.
    func testRejectsPathSeparatorsAndControlCharacters() {
        XCTAssertEqual(AlbumNameValidator.violation(in: "Trip/2023"), .forbiddenCharacter("/"))
        XCTAssertEqual(AlbumNameValidator.violation(in: "Trip: Rome"), .forbiddenCharacter(":"))
        XCTAssertEqual(AlbumNameValidator.violation(in: "Trip\u{0}Rome"), .forbiddenCharacter("\u{0}"))
        XCTAssertEqual(AlbumNameValidator.violation(in: "Trip\u{7}Rome"), .forbiddenCharacter("\u{7}"))
    }

    func testAcceptsEverythingElseAKeyboardProduces() {
        for name in ["Trip 2.0", "Nov. 2023", ".secret", "...", "Q&A #1?", "日本 旅行", "Album_abc+def==", "Trip ", "Ka\u{0308}se"] {
            XCTAssertNil(AlbumNameValidator.violation(in: name), "\(name.debugDescription) should be valid")
            XCTAssertTrue(AlbumNameValidator.isValid(name))
        }
    }
}
