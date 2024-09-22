import XCTest
@testable import EncameraCore
import Sodium

class AlbumTests: XCTestCase {

    func testEncryptionAndDecryptionOfAlbumName() {
        // Arrange
        let sodium = Sodium()
        let keyBytes = sodium.secretStream.xchacha20poly1305.key()
        let key = PrivateKey(name: "Test", keyBytes: keyBytes, creationDate: Date())
        let albumName = "TestAlbum"
        let storageOption = StorageType.local // Assuming a case in StorageType enum

        let album = Album(name: albumName, storageOption: storageOption, creationDate: Date(), key: key)

        // Act
        let encryptedName = album.encryptedPathComponent
        let decryptedName = Album.decryptAlbumName(encryptedName, key: key)

        // Assert
        XCTAssertNotEqual(albumName, encryptedName, "Album name should be encrypted")
        XCTAssertEqual(decryptedName, albumName, "Decrypted name should match the original album name")
    }

    func testInvalidDecryptionReturnsOriginalString() {
        // Arrange
        let sodium = Sodium()
        let keyBytes = sodium.secretStream.xchacha20poly1305.key()
        let key = PrivateKey(name: "Test", keyBytes: keyBytes, creationDate: Date())
        let invalidEncryptedName = "Invalid_Album_Name"

        // Act
        let decryptedName = Album.decryptAlbumName(invalidEncryptedName, key: key)

        // Assert
        XCTAssertEqual(decryptedName, invalidEncryptedName, "Invalid encrypted name should return the original string")
    }

    func testIdGeneration() {
        // Arrange
        let sodium = Sodium()
        let keyBytes = sodium.secretStream.xchacha20poly1305.key()
        let key = PrivateKey(name: "Test", keyBytes: keyBytes, creationDate: Date())
        let albumName = "TestAlbum"
        let storageOption = StorageType.local // Assuming a case in StorageType enum

        let album = Album(name: albumName, storageOption: storageOption, creationDate: Date(), key: key)

        // Act
        let generatedId = album.id

        // Assert
        XCTAssertEqual(generatedId, "\(albumName)_\(storageOption.rawValue)", "ID should be correctly generated based on name and storage option")
    }

    func testDecryptionWithWrongKeyFails() {
        // Arrange
        let sodium = Sodium()
        let keyBytes = sodium.secretStream.xchacha20poly1305.key()
        let wrongKeyBytes = sodium.secretStream.xchacha20poly1305.key()
        let key = PrivateKey(name: "Test", keyBytes: keyBytes, creationDate: Date())
        let wrongKey = PrivateKey(name: "Test", keyBytes: wrongKeyBytes, creationDate: Date())
        let albumName = "TestAlbum"
        let album = Album(name: albumName, storageOption: .local, creationDate: Date(), key: key)

        // Act
        let encryptedName = album.encryptedPathComponent
        let decryptedNameWithWrongKey = Album.decryptAlbumName(encryptedName, key: wrongKey)

        // Assert
        XCTAssertNotEqual(decryptedNameWithWrongKey, albumName, "Decryption with a wrong key should not match the original album name")
    }
}
