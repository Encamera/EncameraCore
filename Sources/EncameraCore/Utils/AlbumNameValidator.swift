//
//  AlbumNameValidator.swift
//  EncameraCore
//

import Foundation

/// Rejects album names that cannot be a directory name on the filesystems
/// Encamera writes to — APFS, HFS+ and iCloud Drive.
///
/// An album's plaintext name only becomes a path when name encryption cannot
/// run, but `.` and `..` then resolve to the albums directory and the storage
/// root, and a separator splits the name into a path. Refusing them at entry
/// is cheaper than recovering from either.
public enum AlbumNameValidator {

    public enum Violation: Equatable {
        case empty
        case reservedName
        case forbiddenCharacter(Character)
    }

    /// The first violation in `name`, or `nil` when it is a usable name.
    public static func violation(in name: String) -> Violation? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if directoryEntries.contains(name) { return .reservedName }
        if let character = name.first(where: isForbidden) { return .forbiddenCharacter(character) }
        return nil
    }

    public static func isValid(_ name: String) -> Bool {
        violation(in: name) == nil
    }

    /// Throws the `AlbumError` an album manager reports for `name`.
    public static func validate(_ name: String) throws {
        switch violation(in: name) {
        case .none:
            return
        case .empty:
            throw AlbumError.albumNameError
        case .reservedName, .forbiddenCharacter:
            throw AlbumError.albumNameForbidden
        }
    }

    /// Present in every directory; can never be created.
    private static let directoryEntries: Set<String> = [".", ".."]

    /// `/` is the POSIX path separator, `:` the HFS one that Finder and iCloud
    /// Drive still refuse; control characters are never part of a name.
    private static let forbiddenCharacters = CharacterSet(charactersIn: "/:").union(.controlCharacters)

    private static func isForbidden(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: forbiddenCharacters.contains)
    }
}
