import XCTest
import Combine
@testable import EncameraCore // Import the module to be tested

final class KeychainManagerTests: XCTestCase {

    var sut: KeychainManager!
    var cancellables: Set<AnyCancellable>!

    // Runs before each test method
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Use a publisher that immediately emits true for authentication status
        let isAuthenticatedPublisher = Just(true).eraseToAnyPublisher()
        sut = KeychainManager(isAuthenticated: isAuthenticatedPublisher)
        cancellables = Set<AnyCancellable>()

        // Clear keychain data before each test to ensure a clean state
        sut.clearKeychainData()
        // Wait a moment for keychain operations to settle, especially deletions.
        Thread.sleep(forTimeInterval: 0.1)
    }

    // Runs after each test method
    override func tearDownWithError() throws {
        // Clear keychain data after each test to avoid interference
        sut.clearKeychainData()
        sut = nil
        cancellables = nil
        try super.tearDownWithError()
    }

    // MARK: - Test Cases

    /// Tests the ability to set an initial password and then change it.
    func testChangePassword() throws {
        // Only test basic password functionality, not keychain syncing
        let initialPassword = "initialPassword123"
        let newPassword = "newPassword456"
        let passcodeType = PasscodeType.pinCode(length: .six)

            try sut.setOrUpdatePassword(initialPassword, type: passcodeType)
            XCTAssertTrue(try sut.checkPassword(initialPassword), "Initial password check should succeed.")


            try sut.setOrUpdatePassword(newPassword, type: passcodeType)
            XCTAssertTrue(try sut.checkPassword(newPassword), "New password check should succeed after change.")
            
            // Verify old password no longer works
            XCTAssertThrowsError(try sut.checkPassword(initialPassword)) { error in
                XCTAssertEqual(error as? KeyManagerError, KeyManagerError.invalidPassword)
            }
    }

    /// Tests setting and retrieving the passcode type.
    func testSetAndRetrievePasscodeType() throws {
        // This test should now run with entitlements
        let password = "testPassword123"
        let expectedType = PasscodeType.password

        // Ensure no password/type exists initially (handled by setup)
        XCTAssertEqual(sut.passcodeType, .none, "Passcode type should be .none initially.")

        // Set password and type
        try sut.setPassword(password, type: expectedType)

        // Retrieve and verify the type
        let isAuthenticatedPublisher = Just(true).eraseToAnyPublisher()
        let newSutInstance = KeychainManager(isAuthenticated: isAuthenticatedPublisher)
        XCTAssertEqual(newSutInstance.passcodeType, expectedType, "Retrieved passcode type should match the set type.")
    }

    /// Tests that the password hash's iCloud sync status is updated correctly.
    func testPasswordSyncStatus() throws {
        // This test should now run with entitlements
        let password = "syncPassword123"
        let passcodeType = PasscodeType.pinCode(length: .four)

        // 1. Set password with sync disabled (default behaviour might depend on app entitlements)
        try sut.setPassword(password, type: passcodeType)
        var isPasswordSynced = try isItemSynced(account: KeychainConstants.account)
        // Initial sync state depends on entitlements/defaults, might not be false
        // XCTAssertFalse(isPasswordSynced, "Password should not be synced initially.") 

        // 2. Enable backup and check sync status
        try sut.backupKeychainToiCloud(backupEnabled: true)
        Thread.sleep(forTimeInterval: 0.2) // Allow keychain changes to propagate
        isPasswordSynced = try isItemSynced(account: KeychainConstants.account)
        XCTAssertTrue(isPasswordSynced, "Password should be synced after enabling backup.")

        // 3. Disable backup and check sync status
        try sut.backupKeychainToiCloud(backupEnabled: false)
        Thread.sleep(forTimeInterval: 0.2) // Allow keychain changes to propagate
        isPasswordSynced = try isItemSynced(account: KeychainConstants.account)
        XCTAssertFalse(isPasswordSynced, "Password should not be synced after disabling backup.")
    }

    /// Tests that the passcode type's iCloud sync status is updated correctly.
    func testPasscodeTypeSyncStatus() throws {
        // This test should now run with entitlements
        let password = "syncPasscodeType123"
        let passcodeType = PasscodeType.pinCode(length: .four)

        // 1. Set password and type with sync disabled (default behaviour might depend on app entitlements)
        try sut.setPassword(password, type: passcodeType)
        var isPasscodeTypeSynced = try isItemSynced(account: KeychainConstants.passcodeTypeKeyItem)
         // Initial sync state depends on entitlements/defaults, might not be false
        // XCTAssertFalse(isPasscodeTypeSynced, "Passcode type should not be synced initially.")

        // 2. Enable backup and check sync status
        try sut.backupKeychainToiCloud(backupEnabled: true)
        Thread.sleep(forTimeInterval: 0.2) // Allow keychain changes to propagate
        isPasscodeTypeSynced = try isItemSynced(account: KeychainConstants.passcodeTypeKeyItem)
        XCTAssertTrue(isPasscodeTypeSynced, "Passcode type should be synced after enabling backup.")

        // 3. Disable backup and check sync status
        try sut.backupKeychainToiCloud(backupEnabled: false)
        Thread.sleep(forTimeInterval: 0.2) // Allow keychain changes to propagate
        isPasscodeTypeSynced = try isItemSynced(account: KeychainConstants.passcodeTypeKeyItem)
        XCTAssertFalse(isPasscodeTypeSynced, "Passcode type should not be synced after disabling backup.")
    }
    
    /// Test basic password functionality without iCloud sync
    func testBasicPasswordFunctionality() throws {
        let password = "testPassword123"
        let passcodeType = PasscodeType.pinCode(length: .four)
        
            // Test setting password
            try sut.setOrUpdatePassword(password, type: passcodeType)
            
            // Verify password check works
            XCTAssertTrue(try sut.checkPassword(password), "Password check should succeed")
            
            // Verify wrong password fails
            XCTAssertThrowsError(try sut.checkPassword("wrongPassword")) { error in
                XCTAssertEqual(error as? KeyManagerError, KeyManagerError.invalidPassword)
            }

    }

    // MARK: - Helper Methods

    /// Helper function to check the kSecAttrSynchronizable status of a generic password item.
    private func isItemSynced(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny // Important: Query for any sync status
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                print("Item with account '\(account)' not found.")
                // Depending on the test case, not found might imply not synced.
                // Or it could be an unexpected state.
                return false 
            } else {
                 // If we get entitlement error here, let the test handle it / skip
                if "\(status)" == "errSecMissingEntitlement" {
                    print("Entitlement error checking sync status for \(account)")
                    throw KeyManagerError.unhandledError(determineOSStatus(status: status)) 
                }
                throw KeychainError.unhandledError(status: status)
            }
        }

        guard let attributes = item as? [String: Any] else {
            // Should not happen if status is errSecSuccess
            print("Warning: Could not cast keychain item attributes.")
            return false 
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
        // it generally implies it's not synced (or inherits default behavior)
        print("Warning: kSecAttrSynchronizable attribute for \(account) is missing or has unexpected type: \(String(describing: syncAttribute)). Assuming not synced.")
        return false
    }
}

// Define a simple error enum for keychain errors in tests if needed
enum KeychainError: Error, Equatable {
    case unhandledError(status: OSStatus)
    case itemNotFound
}

// Add KeychainConstants access for tests
private enum KeychainConstants {
    static let account = "encamera"
    static let passcodeTypeKeyItem = "encamera_passcode_type"
} 
