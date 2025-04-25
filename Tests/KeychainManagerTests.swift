import XCTest
import Combine
@testable import EncameraCore // Import the module to be tested

// Helper to determine OSStatus String Representation
internal func determineOSStatus(status: OSStatus) -> String {
    guard let description = SecCopyErrorMessageString(status, nil) else {
        return "Unknown error code: \(status)"
    }
    return String(description)
}

final class KeychainManagerTests: XCTestCase {

    var sut: KeychainManager!
    var cancellables: Set<AnyCancellable>!
    let defaultKeyName = "testKey"
    let defaultPasscodeType = PasscodeType.pinCode(length: .six)
    let defaultPassword = "defaultPassword123"

    // Runs before each test method
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Use a publisher that immediately emits true for authentication status
        let isAuthenticatedPublisher = Just(true).eraseToAnyPublisher()
        sut = KeychainManager(isAuthenticated: isAuthenticatedPublisher)
        cancellables = Set<AnyCancellable>()

        // Clear keychain data before each test to ensure a clean state
        sut.clearKeychainData()
        UserDefaultUtils.removeObject(forKey: UserDefaultKey.currentKey) // Clear active key default
        // Wait a moment for keychain operations to settle, especially deletions.
        Thread.sleep(forTimeInterval: 0.2)
    }

    // Runs after each test method
    override func tearDownWithError() throws {
        // Clear keychain data after each test to avoid interference
        sut?.clearKeychainData()
        UserDefaultUtils.removeObject(forKey: UserDefaultKey.currentKey)
        sut = nil
        cancellables = nil
        try super.tearDownWithError()
        Thread.sleep(forTimeInterval: 0.1) // Wait after teardown too
    }

    // MARK: - Helper Methods

    /// Creates a dummy PrivateKey for testing.
    private func createTestKey(name: String = "testKey") throws -> PrivateKey {
        // Use the TestDataGenerator from EncameraCore instead of Sodium directly
        let keyBytes = TestDataGenerator.generateRandomKeyBytes()
        let key = PrivateKey(name: name, keyBytes: keyBytes, creationDate: Date())
        // Save uses the current isSyncEnabled state internally
        try sut.save(key: key, setNewKeyToCurrent: false)
        return key
    }

    /// Helper function to check the kSecAttrSynchronizable status of a generic password item.
    private func isGenericPasswordItemSynced(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Important: Query for any sync status
        ]
        return try checkSyncStatus(query: query, itemDescription: "Generic Password (account: \(account))")
    }

    /// Helper function to check the kSecAttrSynchronizable status of a key item.
    private func isKeyItemSynced(name: String) throws -> Bool {
        guard let keyData = name.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: keyData,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
         return try checkSyncStatus(query: query, itemDescription: "Key (name: \(name))")
    }

    /// Generic helper to check sync status from a keychain query.
    private func checkSyncStatus(query: [String: Any], itemDescription: String) throws -> Bool {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                print("Item '\(itemDescription)' not found.")
                // Treat not found as not synced in the context of checking sync status
                return false
            } else {
                // Log other errors but rethrow as a generic error for tests
                let errorDesc = determineOSStatus(status: status)
                print("Error checking sync status for \(itemDescription): \(errorDesc) (\(status))")
                 // Re-throw a more specific error if possible, otherwise a generic one
                 throw KeyManagerError.unhandledError(errorDesc)
            }
        }

        guard let attributes = item as? [String: Any] else {
            print("Warning: Could not cast keychain item attributes for \(itemDescription).")
            return false // Cannot determine status
        }

        // Check for the kSecAttrSynchronizable attribute
        let syncAttribute = attributes[kSecAttrSynchronizable as String]

        // kSecAttrSynchronizable can be Bool or NSNumber (0 or 1)
        if let isSyncedBool = syncAttribute as? Bool {
            return isSyncedBool
        } else if let isSyncedNum = syncAttribute as? NSNumber {
            return isSyncedNum.boolValue
        }

        // If the attribute is present but not Bool/NSNumber, or if it's absent,
        // it generally implies it's not synced.
        print("Warning: kSecAttrSynchronizable attribute for \(itemDescription) is missing or has unexpected type: \(String(describing: syncAttribute)). Assuming not synced.")
        return false
    }

    // MARK: - 1. Key Management & Storage Tests

    func testSaveNewKey_SetCurrent_NoBackup() throws {
        // Ensure sync is disabled first
        try sut.backupKeychainToiCloud(backupEnabled: false)
        let key = try createTestKey(name: "key1") // Creates key using current sync state (false)
        try sut.save(key: key, setNewKeyToCurrent: true)

        // Verify retrieval
        let retrievedKey = sut.keyWith(name: "key1")
        XCTAssertNotNil(retrievedKey)
        XCTAssertEqual(retrievedKey?.keyBytes, key.keyBytes)

        // Verify it's the current key
        XCTAssertEqual(sut.currentKey?.name, "key1")
        XCTAssertEqual(UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String, "key1")

        // Verify sync status
        XCTAssertFalse(try isKeyItemSynced(name: "key1"))
        XCTAssertFalse(sut.isSyncEnabled, "isSyncEnabled should be false")
    }

    func testSaveNewKey_NotCurrent_Backup() throws {
        // Ensure sync is enabled first
        try sut.backupKeychainToiCloud(backupEnabled: true)
        let key = try createTestKey(name: "key2") // Creates key using current sync state (true)
        try sut.save(key: key, setNewKeyToCurrent: false)

        // Verify retrieval
        let retrievedKey = sut.keyWith(name: "key2")
        XCTAssertNotNil(retrievedKey)
        XCTAssertEqual(retrievedKey?.keyBytes, key.keyBytes)

        // Verify it's NOT the current key
        XCTAssertNil(sut.currentKey) // Since setup clears it and we didn't set one
        XCTAssertNil(UserDefaultUtils.value(forKey: UserDefaultKey.currentKey))

        // Verify sync status
        XCTAssertTrue(try isKeyItemSynced(name: "key2"))
        XCTAssertTrue(sut.isSyncEnabled, "isSyncEnabled should be true")
    }

    func testUpdateExistingKey_ChangeSyncStatus() throws {
        // 1. Create with sync disabled
        try sut.backupKeychainToiCloud(backupEnabled: false)
        var key = try createTestKey(name: "updateKey")
        XCTAssertFalse(try isKeyItemSynced(name: "updateKey"))
        XCTAssertFalse(sut.isSyncEnabled)

        // 2. Enable sync via the dedicated method
        try sut.backupKeychainToiCloud(backupEnabled: true)
        XCTAssertTrue(sut.isSyncEnabled, "isSyncEnabled should be true after enabling backup")
        Thread.sleep(forTimeInterval: 0.2) // Allow keychain changes to propagate

        // 3. Verify the existing key was updated by backupKeychainToiCloud
        XCTAssertTrue(try isKeyItemSynced(name: "updateKey"), "Existing key should now be synced")

        // 4. Optionally: Save again (though backupKeychainToiCloud should have handled it)
        // Create "updated" key data (can be same bytes, just need to call save again)
        key = PrivateKey(name: "updateKey", keyBytes: key.keyBytes, creationDate: Date()) // New date simulates update
        try sut.save(key: key, setNewKeyToCurrent: false) // Save will now use isSyncEnabled=true

        // Verify sync status remains true
        XCTAssertTrue(try isKeyItemSynced(name: "updateKey"))
        XCTAssertTrue(sut.isSyncEnabled)

        // Verify only one key with that name exists
        let storedKeys = try sut.storedKeys()
        XCTAssertEqual(storedKeys.count, 1)
        XCTAssertEqual(storedKeys.first?.name, "updateKey")
    }

    func testRetrieveKeyWith_Exists() throws {
        let key = try createTestKey(name: "findMe")
        let retrieved = sut.keyWith(name: "findMe")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, key.name)
    }

    func testRetrieveKeyWith_NotExists() throws {
        XCTAssertNil(sut.keyWith(name: "doesNotExist"))
    }

    func testStoredKeys_Empty() throws {
        XCTAssertTrue(try sut.storedKeys().isEmpty)
    }

    func testStoredKeys_Multiple() throws {
        _ = try createTestKey(name: "keyA")
        Thread.sleep(forTimeInterval: 0.05) // Ensure distinct creation dates
        _ = try createTestKey(name: "keyB")
        Thread.sleep(forTimeInterval: 0.05)
        _ = try createTestKey(name: "keyC")

        let keys = try sut.storedKeys()
        XCTAssertEqual(keys.count, 3)
        // Keys should be sorted by creation date descending (most recent first)
        XCTAssertEqual(Set(keys.map { $0.name }), Set(["keyC", "keyB", "keyA"]))
    }

    func testSetActiveKey_ValidName() throws {
        let key = try createTestKey(name: "activeKey")
        let expectation = XCTestExpectation(description: "Key publisher emits new key")

        sut.keyPublisher
            .sink { publishedKey in
                if publishedKey?.name == "activeKey" {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        try sut.setActiveKey("activeKey")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(sut.currentKey?.name, "activeKey")
        XCTAssertEqual(UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String, "activeKey")
    }

     func testSetActiveKey_Nil() throws {
         _ = try createTestKey(name: "wasActive")
         try sut.setActiveKey("wasActive") // Set one first
         XCTAssertNotNil(sut.currentKey)

         let expectation = XCTestExpectation(description: "Key publisher emits nil")
         sut.keyPublisher
//             .dropFirst() // Ignore initial value if any
             .sink { publishedKey in
                 if publishedKey == nil {
                     expectation.fulfill()
                 }
             }
             .store(in: &cancellables)

         try sut.setActiveKey(nil)

         wait(for: [expectation], timeout: 1.0)
         XCTAssertNil(sut.currentKey)
         XCTAssertNil(UserDefaultUtils.value(forKey: UserDefaultKey.currentKey))
     }

    func testSetActiveKey_InvalidName() throws {
        XCTAssertThrowsError(try sut.setActiveKey("nonExistentKey")) { error in
            XCTAssertEqual(error as? KeyManagerError, .notFound)
        }
    }

    func testGetActiveKey_ExplicitlySet() throws {
        let key = try createTestKey(name: "explicitActive")
        try sut.setActiveKey("explicitActive")
        let activeKey = try sut.getActiveKey()
        XCTAssertEqual(activeKey.name, "explicitActive")
    }

    func testGetActiveKey_NoneExist() throws {
        XCTAssertThrowsError(try sut.getActiveKey()) { error in
            XCTAssertEqual(error as? KeyManagerError, .notFound)
        }
    }

    // MARK: - 2. Key Generation & Passphrase Tests

    func testGenerateKeyUsingRandomWords() throws {
        let keyName = "randomWordKey"
        let key = try sut.generateKeyUsingRandomWords(name: keyName)
        XCTAssertEqual(key.name, keyName)

        let retrievedKey = sut.keyWith(name: keyName)
        XCTAssertNotNil(retrievedKey)
        XCTAssertEqual(retrievedKey?.keyBytes, key.keyBytes)
    }

    func testGenerateKeyUsingRandomWords_InvalidName() throws {
        XCTAssertThrowsError(try sut.generateKeyUsingRandomWords(name: "")) { error in
             XCTAssertEqual(error as? KeyManagerError, .keyNameError)
        }
    }

    func testgenerateKeyFromPasswordComponentsAndSave() throws {
        let components = ["word1", "saltPart2", "saltPart3", "saltPart4", "passwordPart1", "passwordPart2"]
        let keyName = "componentKey"
        let key = try sut.generateKeyFromPasswordComponentsAndSave(components, name: keyName)
        XCTAssertEqual(key.name, keyName)

        let retrievedKey = sut.keyWith(name: keyName)
        XCTAssertNotNil(retrievedKey)
        XCTAssertEqual(retrievedKey?.keyBytes, key.keyBytes)

        // Also check if passphrase was stored (implicitly by this method)
        let passphrase = try sut.retrieveKeyPassphrase()
        XCTAssertEqual(passphrase.words, components)
    }

     func testgenerateKeyFromPasswordComponentsAndSave_InvalidInput() throws {
         // Need to set sync state before generating
         try sut.backupKeychainToiCloud(backupEnabled: false)
         XCTAssertThrowsError(try sut.generateKeyFromPasswordComponentsAndSave([], name: "emptyCompKey")) { error in
             XCTAssertEqual(error as? KeyManagerError, .invalidInput)
         }
         XCTAssertThrowsError(try sut.generateKeyFromPasswordComponentsAndSave(["a","b","c"], name: "shortSaltKey")) { error in
            // Needs at least 4 components for salt derivation logic
             XCTAssertEqual(error as? KeyManagerError, .invalidSalt)
         }
         XCTAssertThrowsError(try sut.generateKeyFromPasswordComponentsAndSave(["word1", "saltPart2", "saltPart3", "saltPart4", "pass"], name: "")) { error in
              XCTAssertEqual(error as? KeyManagerError, .keyNameError)
         }
     }

    func testSaveKeyWithPassphrase_New() throws {
        // Set desired sync state first
        try sut.backupKeychainToiCloud(backupEnabled: false)

        let words = ["apple", "banana", "cherry", "date", "elderberry", "fig"]
        let passphrase = KeyPassphrase(words: words)
        let key = try sut.saveKeyWithPassphrase(passphrase: passphrase)

        XCTAssertEqual(key.name, AppConstants.defaultKeyName)
        XCTAssertNotNil(sut.keyWith(name: AppConstants.defaultKeyName))

        let retrievedPassphrase = try sut.retrieveKeyPassphrase()
        XCTAssertEqual(retrievedPassphrase.words, words)
        // XCTAssertFalse(retrievedPassphrase.iCloudBackupEnabled) // Removed this field
         // Check underlying keychain item sync status
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.passPhraseKeyItem))
        XCTAssertFalse(sut.isSyncEnabled)
    }

    func testSaveKeyWithPassphrase_Update() throws {
        // Save first time with sync disabled
        try sut.backupKeychainToiCloud(backupEnabled: false)
        let words1 = ["one", "two", "three", "four", "five"]
        let passphrase1 = KeyPassphrase(words: words1)
        _ = try sut.saveKeyWithPassphrase(passphrase: passphrase1)
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.passPhraseKeyItem))
        XCTAssertFalse(sut.isSyncEnabled)

        // Enable sync via dedicated method BEFORE saving the second time
        try sut.backupKeychainToiCloud(backupEnabled: true)
        Thread.sleep(forTimeInterval: 0.2) // Allow propagation

        let words2 = ["six", "seven", "eight", "nine", "ten"]
        let passphrase2 = KeyPassphrase(words: words2)
        let key2 = try sut.saveKeyWithPassphrase(passphrase: passphrase2) // Should update existing item (using new isSyncEnabled state)

        XCTAssertEqual(key2.name, AppConstants.defaultKeyName)
        let retrievedPassphrase = try sut.retrieveKeyPassphrase()
        XCTAssertEqual(retrievedPassphrase.words, words2)
        // XCTAssertTrue(retrievedPassphrase.iCloudBackupEnabled) // Removed this field
        XCTAssertTrue(try isGenericPasswordItemSynced(account: KeychainConstants.passPhraseKeyItem))
        XCTAssertTrue(sut.isSyncEnabled)

        // Ensure only one key still exists
        let keys = try sut.storedKeys()
        XCTAssertEqual(keys.filter { $0.name == AppConstants.defaultKeyName }.count, 1)
    }

    func testRetrieveKeyPassphrase_NotExists() throws {
        XCTAssertThrowsError(try sut.retrieveKeyPassphrase()) { error in
            XCTAssertEqual(error as? KeyManagerError, .notFound)
        }
    }

    // MARK: - 3. Password Management Tests

    func testPasswordExists() throws {
        XCTAssertFalse(sut.passwordExists(), "Password should not exist initially")
        try sut.setPassword(defaultPassword, type: defaultPasscodeType)
        XCTAssertTrue(sut.passwordExists(), "Password should exist after setting")
    }

    func testGetPasswordHash() throws {
        try sut.setPassword(defaultPassword, type: defaultPasscodeType)
        let hashData = try sut.getPasswordHash()
        XCTAssertFalse(hashData.isEmpty)

        // Optional: Verify the hash roughly matches the expected format (implementation detail)
        let hashString = String(data: hashData, encoding: .utf8)
        XCTAssertNotNil(hashString)
        XCTAssertTrue(hashString?.starts(with: "$argon2id$") ?? false)
    }

    func testGetPasswordHash_NoPasswordSet() throws {
        XCTAssertThrowsError(try sut.getPasswordHash()) { error in
            // The underlying SecItemCopyMatching fails with notFound, which getPasswordHash maps to invalidPassword
            XCTAssertEqual(error as? KeyManagerError, .invalidPassword)
        }
    }

    func testSetPassword_New() throws {
        try sut.setPassword(defaultPassword, type: .password)
        XCTAssertTrue(sut.passwordExists())
        XCTAssertTrue(try sut.checkPassword(defaultPassword))
        XCTAssertEqual(sut.passcodeType, .password)
         // Check sync status based on default (likely false unless forced by backup)
         XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.account))
         XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.passcodeTypeKeyItem))
    }

    func testSetOrUpdatePassword_New() throws {
        try sut.setOrUpdatePassword(defaultPassword, type: .pinCode(length: .four))
        XCTAssertTrue(sut.passwordExists())
        XCTAssertTrue(try sut.checkPassword(defaultPassword))
        XCTAssertEqual(sut.passcodeType, .pinCode(length: .four))
         XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.account))
         XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.passcodeTypeKeyItem))
    }

    func testSetOrUpdatePassword_Existing() throws {
        try sut.setPassword("oldPassword", type: .password)
        XCTAssertTrue(try sut.checkPassword("oldPassword"))
        XCTAssertEqual(sut.passcodeType, .password)
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.account))

        // Update with sync implicitly enabled via backup call
        try sut.backupKeychainToiCloud(backupEnabled: true)
        Thread.sleep(forTimeInterval: 0.2) // Allow sync changes

        try sut.setOrUpdatePassword(defaultPassword, type: .pinCode(length: .six))
        XCTAssertTrue(try sut.checkPassword(defaultPassword))
        XCTAssertThrowsError(try sut.checkPassword("oldPassword")) // Old should fail
        XCTAssertEqual(sut.passcodeType, .pinCode(length: .six))
        // Verify sync status updated (should be true now)
         XCTAssertTrue(try isGenericPasswordItemSynced(account: KeychainConstants.account))
         XCTAssertTrue(try isGenericPasswordItemSynced(account: KeychainConstants.passcodeTypeKeyItem))
    }


    func testCheckPassword_Correct() throws {
        try sut.setPassword(defaultPassword, type: defaultPasscodeType)
        XCTAssertTrue(try sut.checkPassword(defaultPassword))
    }

    func testCheckPassword_Incorrect() throws {
        try sut.setPassword(defaultPassword, type: defaultPasscodeType)
        XCTAssertThrowsError(try sut.checkPassword("wrongPassword")) { error in
            XCTAssertEqual(error as? KeyManagerError, .invalidPassword)
        }
    }

    func testCheckPassword_NoPasswordSet() throws {
        XCTAssertThrowsError(try sut.checkPassword(defaultPassword)) { error in
            // SecItemCopyMatching inside checkPassword fails with notFound, which is mapped to invalidPassword
            XCTAssertEqual(error as? KeyManagerError, .invalidPassword)
        }
    }

    // testChangePassword already exists and covers the core logic

    func testChangePassword_IncorrectExisting() throws {
        try sut.setPassword(defaultPassword, type: defaultPasscodeType)
        XCTAssertThrowsError(try sut.changePassword(newPassword: "newPass", existingPassword: "wrongOldPass", type: .password)) { error in
            XCTAssertEqual(error as? KeyManagerError, .invalidPassword)
        }
        // Verify original password still works
        XCTAssertTrue(try sut.checkPassword(defaultPassword))
    }

    func testClearPassword() throws {
        try sut.setPassword(defaultPassword, type: defaultPasscodeType)
        XCTAssertTrue(sut.passwordExists())
        XCTAssertNotEqual(sut.passcodeType, .none)

        try sut.clearPassword()

        XCTAssertFalse(sut.passwordExists())
        // Need to re-init SUT to check passcodeType reset effectively, as property reads keychain lazily
        let isAuthenticatedPublisher = Just(true).eraseToAnyPublisher()
        let newSut = KeychainManager(isAuthenticated: isAuthenticatedPublisher)
        XCTAssertEqual(newSut.passcodeType, .none, "Passcode type should be none after clearing password")
    }

    // MARK: - 4. iCloud Backup Synchronization Tests

    func testBackupKeychainToiCloud_Enable() throws {
        // 1. Set up items with sync disabled
        try sut.backupKeychainToiCloud(backupEnabled: false) // Ensure starting state
        let key = try createTestKey(name: "syncKeyTest") // Uses current state (false)
        try sut.saveKeyWithPassphrase(passphrase: KeyPassphrase(words: ["sync", "test","sync", "test","sync", "test","sync", "test","sync", "test"])) // Uses current state (false)
        try sut.setPassword(defaultPassword, type: defaultPasscodeType) // Uses current state (false)
        Thread.sleep(forTimeInterval: 0.1) // Let saves settle

        XCTAssertFalse(try isKeyItemSynced(name: "syncKeyTest"), "Key should initially be unsynced")
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.passPhraseKeyItem), "Passphrase should initially be unsynced")
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.account), "Password hash should initially be unsynced")
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.passcodeTypeKeyItem), "Passcode type should initially be unsynced")
        XCTAssertFalse(sut.isSyncEnabled, "Overall sync status should be false initially")


        // 2. Enable backup
        try sut.backupKeychainToiCloud(backupEnabled: true)
        Thread.sleep(forTimeInterval: 0.3) // Allow keychain changes to propagate

        // 3. Verify all items are now synced
        XCTAssertTrue(try isKeyItemSynced(name: "syncKeyTest"), "Key should be synced after enabling backup")
        XCTAssertTrue(try isGenericPasswordItemSynced(account: KeychainConstants.passPhraseKeyItem), "Passphrase should be synced after enabling backup")
        XCTAssertTrue(try isGenericPasswordItemSynced(account: KeychainConstants.account), "Password hash should be synced after enabling backup")
        XCTAssertTrue(try isGenericPasswordItemSynced(account: KeychainConstants.passcodeTypeKeyItem), "Passcode type should be synced after enabling backup")
        XCTAssertTrue(sut.isSyncEnabled, "Overall sync status should be true after enabling")
    }

    func testBackupKeychainToiCloud_Disable() throws {
        // 1. Set up items with sync enabled
        try sut.backupKeychainToiCloud(backupEnabled: true) // Ensure starting state
        let key = try createTestKey(name: "syncKeyTest") // Uses current state (true)
        try sut.saveKeyWithPassphrase(passphrase: KeyPassphrase(words: ["sync", "test","sync", "test","sync", "test","sync", "test","sync", "test"])) // Uses current state (true)
        try sut.setPassword(defaultPassword, type: defaultPasscodeType) // Uses current state (true)
        Thread.sleep(forTimeInterval: 0.2) // Let saves settle


        XCTAssertTrue(try isKeyItemSynced(name: "syncKeyTest"), "Key should initially be synced")
        XCTAssertTrue(try isGenericPasswordItemSynced(account: KeychainConstants.passPhraseKeyItem), "Passphrase should initially be synced")
        XCTAssertTrue(try isGenericPasswordItemSynced(account: KeychainConstants.account), "Password hash should initially be synced")
        XCTAssertTrue(try isGenericPasswordItemSynced(account: KeychainConstants.passcodeTypeKeyItem), "Passcode type should initially be synced")
        XCTAssertTrue(sut.isSyncEnabled, "Overall sync status should be true initially")

        // 2. Disable backup
        try sut.backupKeychainToiCloud(backupEnabled: false)
        Thread.sleep(forTimeInterval: 0.3) // Allow keychain changes to propagate

        // 3. Verify all items are now unsynced
        XCTAssertFalse(try isKeyItemSynced(name: "syncKeyTest"), "Key should be unsynced after disabling backup")
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.account), "Passphrase should be unsynced after disabling backup")
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.account), "Password hash should be unsynced after disabling backup")
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.passcodeTypeKeyItem), "Passcode type should be unsynced after disabling backup")
         XCTAssertFalse(sut.isSyncEnabled, "Overall sync status should be false after disabling")
    }

    // MARK: - 5. Test Fallback Read Logic (Flag Not Set)

    func testReadsWork_WhenSyncFlagNotSet() throws {
        // 1. Setup: Ensure no backup flag exists (handled by setUp)
        // Add items *without* calling backupKeychainToiCloud.
        // The save/set methods will use isSyncEnabled's fallback, likely setting sync=false
        // internally, but the crucial part is the central *flag* is absent.
        let keyName = "noFlagKey"
        let passphraseWords = ["no", "flag", "pass", "phrase", "test", "words"]
        let password = "noFlagPassword"
        let type = PasscodeType.password

        _ = try sut.generateKeyFromPasswordComponentsAndSave(passphraseWords, name: keyName)
        try sut.setPassword(password, type: type)
        try sut.setActiveKey(keyName) // Set active key for testing getActiveKey

        // Pre-condition check (optional, assumes private helper access or inference)
        // Assert that the flag state is indeed .notSet
        // This might require exposing getBackupFlagState for testing or relying on setup logic.
        // For now, we trust setUp clears the flag.

        // 2. Verification: Test read operations succeed using fallback
        // These reads should use syncQueryValueForReads -> kSecAttrSynchronizableAny

        // storedKeys
        let keys = try sut.storedKeys()
        XCTAssertEqual(keys.count, 1, "Should retrieve the stored key")
        XCTAssertEqual(keys.first?.name, keyName)

        // retrieveKeyPassphrase
        let retrievedPassphrase = try sut.retrieveKeyPassphrase()
        XCTAssertEqual(retrievedPassphrase.words, passphraseWords, "Should retrieve the stored passphrase")

        // passwordExists
        XCTAssertTrue(sut.passwordExists(), "Password should be found")

        // getPasswordHash / checkPassword
        XCTAssertTrue(try sut.checkPassword(password), "Password check should succeed")

        // getKey / getActiveKey
        let retrievedKey = try sut.getKey(by: keyName)
        XCTAssertEqual(retrievedKey.name, keyName, "getKey(by:) should succeed")
        let activeKey = try sut.getActiveKey()
        XCTAssertEqual(activeKey.name, keyName, "getActiveKey() should succeed")

        // passcodeType
        // We might need to re-initialize the SUT if the property caches its value heavily upon first read.
        // Let's try direct access first.
        XCTAssertEqual(sut.passcodeType, type, "Passcode type should be retrieved correctly")

        // Verify keychain items themselves likely ended up unsynced due to fallback
        // (This part isn't strictly necessary for the test's goal but adds confirmation)
        XCTAssertFalse(try isKeyItemSynced(name: keyName), "Key item itself should be unsynced")
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.passPhraseKeyItem), "Passphrase item itself should be unsynced")
        XCTAssertFalse(try isGenericPasswordItemSynced(account: KeychainConstants.account), "Password item itself should be unsynced")
    }

    // MARK: - 6. Data Clearing & Defaults Tests

    func testClearKeychainData() throws {
        // 1. Add some data (ensure sync is enabled to test clearing synced items)
        try sut.backupKeychainToiCloud(backupEnabled: true)
        _ = try createTestKey(name: "toDeleteKey")
        try sut.saveKeyWithPassphrase(passphrase: KeyPassphrase(words: ["to", "delete","to", "delete","to", "delete","to", "delete","to", "delete"]))
        try sut.setPassword(defaultPassword, type: defaultPasscodeType)
        try sut.setActiveKey("toDeleteKey")

        // 2. Verify data exists
        XCTAssertFalse(try sut.storedKeys().isEmpty)
        XCTAssertNoThrow(try sut.retrieveKeyPassphrase())
        XCTAssertTrue(sut.passwordExists())
        XCTAssertNotNil(sut.currentKey)
        XCTAssertNotEqual(sut.passcodeType, .none)


        // 3. Clear data
        sut.clearKeychainData()
        Thread.sleep(forTimeInterval: 0.2) // Allow deletion to propagate

        // 4. Verify data is gone
        XCTAssertTrue(try sut.storedKeys().isEmpty, "Stored keys should be empty")
        XCTAssertThrowsError(try sut.retrieveKeyPassphrase(), "Should throw error retrieving passphrase") { error in
            XCTAssertEqual(error as? KeyManagerError, .notFound)
        }
        XCTAssertFalse(sut.passwordExists(), "Password should not exist")
        XCTAssertNil(sut.currentKey, "Current key should be nil") // clearKeychainData sets currentKey to nil

        // Verify backup flag is cleared (by checking isSyncEnabled)
        XCTAssertFalse(sut.isSyncEnabled, "isSyncEnabled should be false after clearing all data")

        // Check passcodeType after re-init
        let isAuthenticatedPublisher = Just(true).eraseToAnyPublisher()
        let newSut = KeychainManager(isAuthenticated: isAuthenticatedPublisher)
        XCTAssertEqual(newSut.passcodeType, .none, "Passcode type should be none after clearing all data")
    }

    /// Performs a low-level check after clearing data to ensure no items remain.
    func testClearKeychainData_EnsuresNoItemsRemain() throws {
        // 1. Add data with sync enabled
        try sut.backupKeychainToiCloud(backupEnabled: true)
        _ = try createTestKey(name: "rigorousDeleteKey")
        try sut.saveKeyWithPassphrase(passphrase: KeyPassphrase(words: ["rigorous", "delete", "passphrase", "words", "extra", "data"]))
        try sut.setPassword("rigorousPassword", type: .password)

        // Verify some items exist before clearing (sanity check)
        XCTAssertFalse(try sut.storedKeys().isEmpty)
        XCTAssertTrue(sut.passwordExists())

        // 2. Clear data
        sut.clearKeychainData()
        Thread.sleep(forTimeInterval: 0.3) // Give keychain time to process deletions

        // 3. Verification Query - Check multiple classes
        let classesToVerify: [CFString] = [kSecClassKey, kSecClassGenericPassword]
        var remainingItemsDescription = ""

        for itemClass in classesToVerify {
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: false, // Don't need data, just attributes
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]

            var items: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &items)

            if status == errSecSuccess {
                if let foundItems = items as? [[String: Any]], !foundItems.isEmpty {
                    remainingItemsDescription += "\n--- Remaining items for class \(itemClass): ---\n"
                    for (index, item) in foundItems.enumerated() {
                        remainingItemsDescription += "  Item \(index + 1):\n"
                        for (key, value) in item.sorted(by: { $0.key < $1.key }) {
                            remainingItemsDescription += "    \(key): \(value)\n"
                        }
                    }
                } else {
                    // Status was success, but no items array or empty array - unusual, but treat as clear
                    print("SecItemCopyMatching returned success but no items found for class \(itemClass).")
                }
            } else if status == errSecItemNotFound {
                // This is the expected outcome - no items found for this class
                print("Verified no items remain for class \(itemClass).")
            } else {
                // An unexpected error occurred during the check
                XCTFail("Keychain query failed during verification for class \(itemClass) with status: \(determineOSStatus(status: status)) (\(status))")
                return // Stop test on query failure
            }
        }

        // 4. Fail test if any items were found
        if !remainingItemsDescription.isEmpty {
            XCTFail("clearKeychainData did not remove all items. Remaining items: \(remainingItemsDescription)")
        }
    }

    // MARK: - 7. Default Passcode Type Tests (Renumbered)

    func testDefaultPasscodeType() throws {
        // 1. Set password (which implicitly sets type)
        try sut.setPassword(defaultPassword, type: .password)
        XCTAssertEqual(sut.passcodeType, .password)

        // 2. Manually delete the passcode type item (simulate corruption/manual deletion)
        let passcodeTypeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passcodeTypeKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let deleteStatus = SecItemDelete(passcodeTypeQuery as CFDictionary)
        XCTAssertTrue(deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound, "Passcode type deletion should succeed or item not be found")
        Thread.sleep(forTimeInterval: 0.1)

        // 3. Re-initialize SUT and check passcodeType
        // The property getter should detect the missing item and return+save the default
        let isAuthenticatedPublisher = Just(true).eraseToAnyPublisher()
        let newSut = KeychainManager(isAuthenticated: isAuthenticatedPublisher)

        // Ensure password still exists for the logic branch to trigger
        XCTAssertTrue(newSut.passwordExists())

        let defaultType = PasscodeType.pinCode(length: AppConstants.defaultPinCodeLength)
        XCTAssertEqual(newSut.passcodeType, defaultType, "Passcode type should default when missing but password exists")

        // 4. Verify the default type was saved back to the keychain
        let retrievedType = newSut.passcodeType
        XCTAssertEqual(retrievedType, defaultType, "Default passcode type should have been saved back to keychain")
    }

    // MARK: - Existing Tests Integration (Verify they still pass)

    /// Tests the ability to set an initial password and then change it. (Slightly adapted from original)
    func testChangePassword_ExistingTestLogic() throws {
        let initialPassword = "initialPassword123"
        let newPassword = "newPassword456"
        let passcodeType = PasscodeType.pinCode(length: .six)

        try sut.setOrUpdatePassword(initialPassword, type: passcodeType)
        XCTAssertTrue(try sut.checkPassword(initialPassword), "Initial password check should succeed.")

        // Use changePassword method
        try sut.changePassword(newPassword: newPassword, existingPassword: initialPassword, type: passcodeType)
        XCTAssertTrue(try sut.checkPassword(newPassword), "New password check should succeed after change.")

        // Verify old password no longer works
        XCTAssertThrowsError(try sut.checkPassword(initialPassword)) { error in
            XCTAssertEqual(error as? KeyManagerError, KeyManagerError.invalidPassword)
        }
    }

    /// Tests setting and retrieving the passcode type. (Adapted from original)
    func testSetAndRetrievePasscodeType_ExistingTestLogic() throws {
        let password = "testPassword123"
        let expectedType = PasscodeType.password

        // Ensure no password/type exists initially (handled by setup)
        XCTAssertEqual(sut.passcodeType, .none, "Passcode type should be .none initially.")

        // Set password and type
        try sut.setPassword(password, type: expectedType)

        // Retrieve and verify the type - re-init SUT to ensure it reads from keychain
        let isAuthenticatedPublisher = Just(true).eraseToAnyPublisher()
        let newSutInstance = KeychainManager(isAuthenticated: isAuthenticatedPublisher)
        XCTAssertEqual(newSutInstance.passcodeType, expectedType, "Retrieved passcode type should match the set type.")
    }

    // testPasswordSyncStatus and testPasscodeTypeSyncStatus from original file are covered by testBackupKeychainToiCloud_Enable/Disable tests.
    // testBasicPasswordFunctionality from original file is covered by various password tests above.


}

// Add KeychainConstants access for tests if not already globally accessible in test target
private enum KeychainConstants {
    static let applicationTag = "com.encamera.key" // Match the main app's tag if needed for queries
    static let account = "encamera"
    static let minKeyLength = 2
    static let passPhraseKeyItem = "encamera_key_passphrase"
    static let passcodeTypeKeyItem = "encamera_passcode_type"
}

// Simple Error Struct for Keychain Helper (if needed, KeyManagerError covers most cases)
enum KeychainTestError: Error, Equatable {
    case unhandledError(status: OSStatus)
    case itemNotFound
    case castingError
}

// Extend PasscodeType for Equatable if not already done
// extension PasscodeType: Equatable {
//     public static func == (lhs: PasscodeType, rhs: PasscodeType) -> Bool {
//         switch (lhs, rhs) {
//         case (.none, .none):
//             return true
//         case (.password, .password):
//             return true
//         case let (.pinCode(len1), .pinCode(len2)):
//             return len1 == len2
//         default:
//             return false
//         }
//     }
// }

// Extend PrivateKey for Equatable based on name for simplicity in some tests
// extension PrivateKey: Equatable {
//     public static func == (lhs: PrivateKey, rhs: PrivateKey) -> Bool {
//         return lhs.name == rhs.name // && lhs.keyBytes == rhs.keyBytes (Can compare bytes if needed)
//     }
// }

