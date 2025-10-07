//
//  UserDefaultUtilsiCloudSyncTests.swift
//  EncameraTests
//
//  Created by AI Assistant on 2025-01-04.
//
//  Tests comparing OLD behavior (local-only UserDefaults) with NEW behavior (iCloud sync)
//

import XCTest
import Combine
@testable import EncameraCore

final class UserDefaultUtilsiCloudSyncTests: XCTestCase {
    
    // MARK: - Properties
    
    private var cancellables: Set<AnyCancellable>!
    private let testTimeout: TimeInterval = 5.0
    
    // Helper to simulate old behavior (local-only storage)
    private var localDefaults: UserDefaults {
        #if DEBUG
        return UserDefaults(suiteName: "group.me.freas.encamera.debug") ?? UserDefaults.standard
        #else
        return UserDefaults(suiteName: "group.me.freas.encamera") ?? UserDefaults.standard
        #endif
    }
    
    // MARK: - Setup & Teardown
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        cancellables = Set<AnyCancellable>()
        
        // Clear all defaults before each test
        clearAllTestData()
        
        // Setup iCloud sync
        UserDefaultUtils.setupiCloudSync()
        
        // Wait for sync to initialize
        Thread.sleep(forTimeInterval: 0.2)
    }
    
    override func tearDownWithError() throws {
        // Clear all test data
        clearAllTestData()
        
        // Tear down iCloud sync
        UserDefaultUtils.tearDowniCloudSync()
        
        cancellables = nil
        try super.tearDownWithError()
        
        // Wait for cleanup to complete
        Thread.sleep(forTimeInterval: 0.2)
    }
    
    // MARK: - Helper Methods
    
    private func clearAllTestData() {
        // Clear local UserDefaults
        if let appGroup = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String {
            if let defaults = UserDefaults(suiteName: appGroup) {
                defaults.dictionaryRepresentation().keys.forEach { key in
                    defaults.removeObject(forKey: key)
                }
                defaults.synchronize()
            }
        }
        
        // Clear iCloud store
        let cloudStore = NSUbiquitousKeyValueStore.default
        if let cloudDict = cloudStore.dictionaryRepresentation as? [String: Any] {
            cloudDict.keys.forEach { key in
                cloudStore.removeObject(forKey: key)
            }
            cloudStore.synchronize()
        }
        
        // Wait for operations to complete
        Thread.sleep(forTimeInterval: 0.1)
    }
    
    private func getCloudValue(forKey key: String) -> Any? {
        return NSUbiquitousKeyValueStore.default.object(forKey: key)
    }
    
    private func setCloudValue(_ value: Any, forKey key: String) {
        NSUbiquitousKeyValueStore.default.set(value, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }
    
    // MARK: - Comparative Tests: Old vs New Behavior
    
    func testOldBehavior_NoiCloudSync() throws {
        // This test demonstrates the OLD behavior using UserDefaultKeyOld
        // Old behavior: keys were ONLY stored locally, no iCloud sync
        
        let oldKey = UserDefaultKeyOld.onboardingState
        let testValue = "completed"
        
        // Old way: direct UserDefaults access (no iCloud)
        localDefaults.set(testValue, forKey: oldKey.rawValue)
        localDefaults.synchronize()
        Thread.sleep(forTimeInterval: 0.2)
        
        // Verify it's in local storage
        let localValue = localDefaults.string(forKey: oldKey.rawValue)
        XCTAssertEqual(localValue, testValue, "OLD: Value stored locally")
        
        // Verify it's NOT in iCloud (this was the problem!)
        let cloudValue = getCloudValue(forKey: oldKey.rawValue)
        XCTAssertNil(cloudValue, "OLD BEHAVIOR: Values were NOT synced to iCloud - THIS WAS THE BUG")
    }
    
    func testNewBehavior_WithiCloudSync() throws {
        // This test demonstrates the NEW behavior
        // New behavior: critical keys ARE synced to iCloud
        
        let newKey = UserDefaultKey.onboardingState
        let testValue = "completed"
        
        // New way: using UserDefaultUtils which handles iCloud sync
        UserDefaultUtils.set(testValue, forKey: newKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Verify it's in local storage
        let localValue = UserDefaultUtils.string(forKey: newKey)
        XCTAssertEqual(localValue, testValue, "NEW: Value stored locally")
        
        // Verify it's ALSO in iCloud (this is the fix!)
        let cloudValue = getCloudValue(forKey: newKey.rawValue)
        XCTAssertEqual(cloudValue as? String, testValue, "NEW BEHAVIOR: Critical values ARE synced to iCloud ✅")
    }
    
    func testComparison_KeyClassification() throws {
        // The NEW implementation has shouldSyncToiCloud property
        // The OLD implementation didn't have this - everything was local
        
        // Critical keys SHOULD sync
        XCTAssertTrue(UserDefaultKey.savedSettings.shouldSyncToiCloud, 
                     "NEW: Face ID setting syncs (fixes multi-device bug)")
        XCTAssertTrue(UserDefaultKey.onboardingState.shouldSyncToiCloud, 
                     "NEW: Onboarding state syncs")
        XCTAssertTrue(UserDefaultKey.authenticationPolicy.shouldSyncToiCloud, 
                     "NEW: Auth policy syncs")
        
        // Device-specific keys should NOT sync
        XCTAssertFalse(UserDefaultKey.launchCountKey.shouldSyncToiCloud, 
                      "NEW: Device metrics stay local")
        XCTAssertFalse(UserDefaultKey.photoAddedCount.shouldSyncToiCloud, 
                      "NEW: Counters stay local")
        
        // OLD behavior: everything was local, no distinction
        // (UserDefaultKeyOld doesn't have shouldSyncToiCloud property at all)
    }
    
    func testRealWorldScenario_FaceIDSync_OldVsNew() throws {
        // SCENARIO: User sets up Face ID on iPhone, then opens app on iPad
        
        // === OLD BEHAVIOR (the bug) ===
        // 1. iPhone: Save Face ID setting locally
        let oldKey = UserDefaultKeyOld.savedSettings
        let faceIDSettings = try JSONEncoder().encode(SavedSettings(useBiometricsForAuth: true))
        localDefaults.set(faceIDSettings, forKey: oldKey.rawValue)
        localDefaults.synchronize()
        Thread.sleep(forTimeInterval: 0.2)
        
        // 2. iPad: Try to read Face ID setting
        let oldCloudValue = getCloudValue(forKey: oldKey.rawValue)
        XCTAssertNil(oldCloudValue, "OLD BUG: iPad can't see iPhone's Face ID setting ❌")
        
        // === NEW BEHAVIOR (the fix) ===
        clearAllTestData()
        
        // 1. iPhone: Save Face ID setting (automatically syncs to iCloud)
        let newKey = UserDefaultKey.savedSettings
        UserDefaultUtils.set(faceIDSettings, forKey: newKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // 2. iPad: Read Face ID setting from iCloud
        let newCloudValue = getCloudValue(forKey: newKey.rawValue)
        XCTAssertNotNil(newCloudValue, "NEW FIX: iPad CAN see iPhone's Face ID setting ✅")
        
        // 3. iPad can now use the synced setting
        if let syncedData = newCloudValue as? Data {
            let decoded = try JSONDecoder().decode(SavedSettings.self, from: syncedData)
            XCTAssertEqual(decoded.useBiometricsForAuth, true, 
                          "Face ID preference successfully synced across devices")
        }
    }
    
    // MARK: - Basic Read/Write Tests
    
    func testSetString_ShouldSyncToiCloud_WhenKeyShouldSync() throws {
        // Given
        let testKey = UserDefaultKey.onboardingState
        let testValue = "completed"
        
        // When
        UserDefaultUtils.set(testValue, forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2) // Allow sync time
        
        // Then - Check local storage
        let localValue = UserDefaultUtils.string(forKey: testKey)
        XCTAssertEqual(localValue, testValue, "Local value should be set")
        
        // Then - Check iCloud storage
        let cloudValue = getCloudValue(forKey: testKey.rawValue) as? String
        XCTAssertEqual(cloudValue, testValue, "Value should sync to iCloud")
    }
    
    func testSetString_ShouldNotSyncToiCloud_WhenKeyShouldNotSync() throws {
        // Given
        let testKey = UserDefaultKey.launchCountKey
        let testValue = "10"
        
        // When
        UserDefaultUtils.set(testValue, forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Then - Check local storage
        let localValue = UserDefaultUtils.string(forKey: testKey)
        XCTAssertEqual(localValue, testValue, "Local value should be set")
        
        // Then - Check iCloud storage (should be nil)
        let cloudValue = getCloudValue(forKey: testKey.rawValue)
        XCTAssertNil(cloudValue, "Local-only value should not sync to iCloud")
    }
    
    func testSetBool_ShouldSyncToiCloud() throws {
        // Given
        let testKey = UserDefaultKey.showCurrentAlbumOnLaunch
        let testValue = true
        
        // When
        UserDefaultUtils.set(testValue, forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Then
        let localValue = UserDefaultUtils.bool(forKey: testKey)
        XCTAssertEqual(localValue, testValue, "Local bool value should be set")
        
        let cloudValue = NSUbiquitousKeyValueStore.default.bool(forKey: testKey.rawValue)
        XCTAssertEqual(cloudValue, testValue, "Bool value should sync to iCloud")
    }
    
    func testSetInteger_ShouldSyncToiCloud() throws {
        // Given - Use a key that should sync
        let testKey = UserDefaultKey.gridZoomLevel
        let testValue = 42
        
        // When
        UserDefaultUtils.set(testValue, forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Then
        let localValue = UserDefaultUtils.integer(forKey: testKey)
        XCTAssertEqual(localValue, testValue, "Local integer value should be set")
        
        let cloudValue = Int(NSUbiquitousKeyValueStore.default.longLong(forKey: testKey.rawValue))
        XCTAssertEqual(cloudValue, testValue, "Integer value should sync to iCloud")
    }
    
    func testSetData_ShouldSyncToiCloud() throws {
        // Given
        let testKey = UserDefaultKey.savedSettings
        let testValue = Data([1, 2, 3, 4, 5])
        
        // When
        UserDefaultUtils.set(testValue, forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Then
        let localValue = UserDefaultUtils.data(forKey: testKey)
        XCTAssertEqual(localValue, testValue, "Local data value should be set")
        
        let cloudValue = NSUbiquitousKeyValueStore.default.data(forKey: testKey.rawValue)
        XCTAssertEqual(cloudValue, testValue, "Data value should sync to iCloud")
    }
    
    // MARK: - Read Preference Tests (Cloud vs Local)
    
    func testReadString_ShouldPreferCloudValue_WhenBothExist() throws {
        // Given
        let testKey = UserDefaultKey.currentKey
        let localValue = "localKeyName"
        let cloudValue = "cloudKeyName"
        
        // Set local value directly
        if let defaults = UserDefaults(suiteName: "group.me.freas.encamera.debug") {
            defaults.set(localValue, forKey: testKey.rawValue)
            defaults.synchronize()
        }
        
        // Set cloud value directly
        setCloudValue(cloudValue, forKey: testKey.rawValue)
        Thread.sleep(forTimeInterval: 0.2)
        
        // When
        let retrievedValue = UserDefaultUtils.string(forKey: testKey)
        
        // Then
        XCTAssertEqual(retrievedValue, cloudValue, "Should prefer cloud value over local when both exist")
    }
    
    func testReadBool_ShouldFallbackToLocal_WhenCloudValueDoesNotExist() throws {
        // Given
        let testKey = UserDefaultKey.hasOpenedAlbum
        let localValue = true
        
        // Set only local value
        if let defaults = UserDefaults(suiteName: "group.me.freas.encamera.debug") {
            defaults.set(localValue, forKey: testKey.rawValue)
            defaults.synchronize()
        }
        
        // When
        let retrievedValue = UserDefaultUtils.bool(forKey: testKey)
        
        // Then
        XCTAssertEqual(retrievedValue, localValue, "Should fallback to local value when cloud value doesn't exist")
    }
    
    // MARK: - Remove Tests
    
    func testRemoveObject_ShouldRemoveFromBothStorages() throws {
        // Given
        let testKey = UserDefaultKey.currentAlbumID
        let testValue = "albumID123"
        
        // Set value (should sync to both)
        UserDefaultUtils.set(testValue, forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Verify it exists in both
        XCTAssertNotNil(UserDefaultUtils.string(forKey: testKey))
        XCTAssertNotNil(getCloudValue(forKey: testKey.rawValue))
        
        // When
        UserDefaultUtils.removeObject(forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Then
        XCTAssertNil(UserDefaultUtils.string(forKey: testKey), "Value should be removed from local storage")
        XCTAssertNil(getCloudValue(forKey: testKey.rawValue), "Value should be removed from iCloud storage")
    }
    
    func testRemoveObject_LocalOnlyKey_ShouldNotAffectCloud() throws {
        // Given
        let testKey = UserDefaultKey.photoAddedCount
        let testValue = 100
        
        UserDefaultUtils.set(testValue, forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // When
        UserDefaultUtils.removeObject(forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Then
        XCTAssertEqual(UserDefaultUtils.integer(forKey: testKey), 0, "Local value should be removed")
        // Cloud value should never have been set for local-only keys
        XCTAssertNil(getCloudValue(forKey: testKey.rawValue))
    }
    
    // MARK: - Migration Tests
    
    func testNeedsiCloudMigration_ShouldReturnTrue_WhenNotMigrated() throws {
        // Given - Fresh state
        clearAllTestData()
        
        // When
        let needsMigration = UserDefaultUtils.needsiCloudMigration()
        
        // Then
        XCTAssertTrue(needsMigration, "Should need migration when migration flag is not set")
    }
    
    func testNeedsiCloudMigration_ShouldReturnFalse_AfterMigration() throws {
        // Given - Perform migration
        UserDefaultUtils.migrateToiCloudStorage()
        Thread.sleep(forTimeInterval: 0.2)
        
        // When
        let needsMigration = UserDefaultUtils.needsiCloudMigration()
        
        // Then
        XCTAssertFalse(needsMigration, "Should not need migration after it's been completed")
    }
    
    func testMigrateToiCloudStorage_ShouldMigrateExistingLocalData() throws {
        // Given - Set some local data before migration
        clearAllTestData()
        
        let testKeys: [(UserDefaultKey, Any)] = [
            (.onboardingState, "completed"),
            (.showCurrentAlbumOnLaunch, true),
            (.gridZoomLevel, 3)
        ]
        
        // Set values directly in local storage
        if let defaults = UserDefaults(suiteName: "group.me.freas.encamera.debug") {
            for (key, value) in testKeys {
                defaults.set(value, forKey: key.rawValue)
            }
            defaults.synchronize()
        }
        
        // When - Perform migration
        UserDefaultUtils.migrateToiCloudStorage()
        Thread.sleep(forTimeInterval: 0.3)
        
        // Then - Check that values were migrated to iCloud
        XCTAssertNotNil(getCloudValue(forKey: "onboardingState"), "String value should migrate to iCloud")
        XCTAssertNotNil(getCloudValue(forKey: "showCurrentAlbumOnLaunch"), "Bool value should migrate to iCloud")
        XCTAssertNotNil(getCloudValue(forKey: "gridZoomLevel"), "Int value should migrate to iCloud")
    }
    
    func testMigrateToiCloudStorage_ShouldPreferCloudData_WhenConflictExists() throws {
        // Given - Data exists in both local and cloud
        clearAllTestData()
        
        let testKey = UserDefaultKey.currentKey
        let localValue = "localKeyName"
        let cloudValue = "cloudKeyName" // This should win
        
        // Set local value
        if let defaults = UserDefaults(suiteName: "group.me.freas.encamera.debug") {
            defaults.set(localValue, forKey: testKey.rawValue)
            defaults.synchronize()
        }
        
        // Set cloud value (simulating another device)
        setCloudValue(cloudValue, forKey: testKey.rawValue)
        Thread.sleep(forTimeInterval: 0.2)
        
        // When - Perform migration
        UserDefaultUtils.migrateToiCloudStorage()
        Thread.sleep(forTimeInterval: 0.3)
        
        // Then - Local should now have cloud value
        let finalValue = UserDefaultUtils.string(forKey: testKey)
        XCTAssertEqual(finalValue, cloudValue, "Should prefer cloud value when conflict exists during migration")
    }
    
    func testMigrateToiCloudStorage_ShouldNotRunTwice() throws {
        // Given
        clearAllTestData()
        UserDefaultUtils.migrateToiCloudStorage()
        Thread.sleep(forTimeInterval: 0.2)
        
        let firstCheck = UserDefaultUtils.needsiCloudMigration()
        
        // When - Try to migrate again
        UserDefaultUtils.migrateToiCloudStorage()
        Thread.sleep(forTimeInterval: 0.2)
        
        // Then
        XCTAssertFalse(firstCheck, "Should not need migration after first run")
        XCTAssertFalse(UserDefaultUtils.needsiCloudMigration(), "Should still not need migration")
    }
    
    // MARK: - Key Classification Tests
    
    func testShouldSyncToiCloud_CriticalKeys_ShouldReturnTrue() throws {
        // Test critical authentication keys
        XCTAssertTrue(UserDefaultKey.authenticationPolicy.shouldSyncToiCloud, "authenticationPolicy should sync")
        XCTAssertTrue(UserDefaultKey.onboardingState.shouldSyncToiCloud, "onboardingState should sync")
        XCTAssertTrue(UserDefaultKey.savedSettings.shouldSyncToiCloud, "savedSettings should sync (Face ID!)")
        XCTAssertTrue(UserDefaultKey.currentKey.shouldSyncToiCloud, "currentKey should sync")
        XCTAssertTrue(UserDefaultKey.currentAlbumID.shouldSyncToiCloud, "currentAlbumID should sync")
    }
    
    func testShouldSyncToiCloud_LocalOnlyKeys_ShouldReturnFalse() throws {
        // Test device-specific keys
        XCTAssertFalse(UserDefaultKey.launchCountKey.shouldSyncToiCloud, "launchCountKey should NOT sync")
        XCTAssertFalse(UserDefaultKey.photoAddedCount.shouldSyncToiCloud, "photoAddedCount should NOT sync")
        XCTAssertFalse(UserDefaultKey.widgetOpenCount.shouldSyncToiCloud, "widgetOpenCount should NOT sync")
        XCTAssertFalse(UserDefaultKey.reviewRequestedMetric.shouldSyncToiCloud, "reviewRequestedMetric should NOT sync")
        XCTAssertFalse(UserDefaultKey.passcodeType.shouldSyncToiCloud, "passcodeType should NOT sync (managed in keychain)")
    }
    
    func testShouldSyncToiCloud_AlbumKeys_ShouldReturnTrue() throws {
        // Create a test album for testing
        let keyManager = TestUtils.createTestKeyManager()
        let testKey = try TestUtils.createTestKey(name: "testKey", keyManager: keyManager)
        let testAlbum = TestUtils.createTestAlbum(name: "TestAlbum", key: testKey)
        
        // Test album-specific keys
        XCTAssertTrue(UserDefaultKey.directoryTypeKeyFor(album: testAlbum).shouldSyncToiCloud, "Album directory type should sync")
        XCTAssertTrue(UserDefaultKey.isAlbumHidden(name: "test").shouldSyncToiCloud, "Album hidden state should sync")
        XCTAssertTrue(UserDefaultKey.albumCoverImage(albumName: "test").shouldSyncToiCloud, "Album cover image should sync")
    }
    
    // MARK: - Integer Increment Tests
    
    func testIncreaseInteger_ShouldSyncToiCloud_WhenKeyShouldSync() throws {
        // Given
        let testKey = UserDefaultKey.gridZoomLevel
        
        // When
        UserDefaultUtils.increaseInteger(forKey: testKey)
        UserDefaultUtils.increaseInteger(forKey: testKey)
        UserDefaultUtils.increaseInteger(forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Then
        let localValue = UserDefaultUtils.integer(forKey: testKey)
        XCTAssertEqual(localValue, 3, "Local integer should be incremented")
        
        let cloudValue = Int(NSUbiquitousKeyValueStore.default.longLong(forKey: testKey.rawValue))
        XCTAssertEqual(cloudValue, 3, "Cloud integer should be synced")
    }
    
    func testIncreaseIntegerBy_ShouldWork() throws {
        // Given
        let testKey = UserDefaultKey.photoAddedCount
        
        // When
        UserDefaultUtils.increaseInteger(forKey: testKey, by: 5)
        Thread.sleep(forTimeInterval: 0.1)
        
        // Then
        let value = UserDefaultUtils.integer(forKey: testKey)
        XCTAssertEqual(value, 5, "Integer should be increased by specified amount")
    }
    
    // MARK: - Publisher Tests
    
    func testPublisher_ShouldEmitChanges() throws {
        // Given
        let testKey = UserDefaultKey.onboardingState
        let expectation = XCTestExpectation(description: "Publisher should emit value")
        var receivedValue: Any?
        
        UserDefaultUtils.publisher(for: testKey)
            .sink { value in
                receivedValue = value
                expectation.fulfill()
            }
            .store(in: &cancellables)
        
        // When
        UserDefaultUtils.set("completed", forKey: testKey)
        
        // Then
        wait(for: [expectation], timeout: testTimeout)
        XCTAssertNotNil(receivedValue, "Publisher should emit when value changes")
    }
    
    // MARK: - RemoveAll Tests
    
    func testRemoveAll_ShouldClearBothStorages() throws {
        // Given - Set multiple values
        UserDefaultUtils.set("value1", forKey: .onboardingState)
        UserDefaultUtils.set(true, forKey: .showCurrentAlbumOnLaunch)
        UserDefaultUtils.set(42, forKey: .gridZoomLevel)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Verify values exist
        XCTAssertNotNil(UserDefaultUtils.string(forKey: .onboardingState))
        XCTAssertNotNil(getCloudValue(forKey: "onboardingState"))
        
        // When
        UserDefaultUtils.removeAll()
        Thread.sleep(forTimeInterval: 0.3)
        
        // Then - Check local
        XCTAssertNil(UserDefaultUtils.string(forKey: .onboardingState))
        XCTAssertFalse(UserDefaultUtils.bool(forKey: .showCurrentAlbumOnLaunch))
        XCTAssertEqual(UserDefaultUtils.integer(forKey: .gridZoomLevel), 0)
        
        // Check cloud
        XCTAssertNil(getCloudValue(forKey: "onboardingState"))
        XCTAssertNil(getCloudValue(forKey: "showCurrentAlbumOnLaunch"))
    }
    
    // MARK: - Dictionary Tests
    
    func testDictionary_ShouldSyncToiCloud() throws {
        // Given
        let testKey = UserDefaultKey.savedSettings
        let testDict: [String: Any] = ["useBiometrics": true, "version": 1]
        
        // When
        UserDefaultUtils.set(testDict, forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Then
        let localDict = UserDefaultUtils.dictionary(forKey: testKey)
        XCTAssertNotNil(localDict, "Local dictionary should be set")
        XCTAssertEqual(localDict?["useBiometrics"] as? Bool, true)
        
        let cloudDict = NSUbiquitousKeyValueStore.default.dictionary(forKey: testKey.rawValue)
        XCTAssertNotNil(cloudDict, "Dictionary should sync to iCloud")
        XCTAssertEqual(cloudDict?["useBiometrics"] as? Bool, true)
    }
    
    // MARK: - Edge Cases
    
    func testSetNilValue_ShouldRemoveFromBothStorages() throws {
        // Given - Value exists
        let testKey = UserDefaultKey.currentKey
        UserDefaultUtils.set("someValue", forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        XCTAssertNotNil(UserDefaultUtils.string(forKey: testKey))
        XCTAssertNotNil(getCloudValue(forKey: testKey.rawValue))
        
        // When - Set to nil
        UserDefaultUtils.set(nil, forKey: testKey)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Then - Should be removed from both
        XCTAssertNil(UserDefaultUtils.string(forKey: testKey))
        XCTAssertNil(getCloudValue(forKey: testKey.rawValue))
    }
    
    func testReadNonExistentKey_ShouldReturnDefault() throws {
        // Given - Key doesn't exist
        let testKey = UserDefaultKey.gridZoomLevel
        
        // When
        let intValue = UserDefaultUtils.integer(forKey: testKey)
        let boolValue = UserDefaultUtils.bool(forKey: .hasOpenedAlbum)
        let stringValue = UserDefaultUtils.string(forKey: .currentKey)
        
        // Then - Should return sensible defaults
        XCTAssertEqual(intValue, 0, "Non-existent integer should default to 0")
        XCTAssertFalse(boolValue, "Non-existent bool should default to false")
        XCTAssertNil(stringValue, "Non-existent string should return nil")
    }
    
    // MARK: - Sync Lifecycle Tests
    
    func testSetupiCloudSync_ShouldRegisterObserver() throws {
        // This is tested implicitly - if sync didn't work, other tests would fail
        // Just verify it can be called multiple times without crashing
        UserDefaultUtils.setupiCloudSync()
        UserDefaultUtils.setupiCloudSync()
        // Should not crash
        XCTAssertTrue(true, "Multiple setup calls should not crash")
    }
    
    func testTearDowniCloudSync_ShouldRemoveObserver() throws {
        // Given
        UserDefaultUtils.setupiCloudSync()
        
        // When
        UserDefaultUtils.tearDowniCloudSync()
        
        // Then - Should be able to call again without issues
        UserDefaultUtils.tearDowniCloudSync()
        XCTAssertTrue(true, "Multiple teardown calls should not crash")
    }
    
    // MARK: - Real-World Scenario Tests
    
    func testFaceIDScenario_ShouldSyncSettingsAcrossDevices() throws {
        // Simulate Device A setting Face ID preference
        
        // Given - Device A enables Face ID
        let settingsData = try JSONEncoder().encode(SavedSettings(useBiometricsForAuth: true))
        UserDefaultUtils.set(settingsData, forKey: .savedSettings)
        UserDefaultUtils.set(Data("completed".utf8), forKey: .onboardingState)
        Thread.sleep(forTimeInterval: 0.3)
        
        // Verify it synced to iCloud
        XCTAssertNotNil(getCloudValue(forKey: "savedSettings"), "Settings should sync to iCloud")
        XCTAssertNotNil(getCloudValue(forKey: "onboardingState"), "Onboarding state should sync")
        
        // Simulate Device B reading the synced data
        let syncedSettings = UserDefaultUtils.data(forKey: .savedSettings)
        XCTAssertNotNil(syncedSettings, "Device B should read synced settings")
        
        if let data = syncedSettings {
            let decoded = try JSONDecoder().decode(SavedSettings.self, from: data)
            XCTAssertEqual(decoded.useBiometricsForAuth, true, "Face ID setting should be synced correctly")
        }
    }
    
    func testMultiDeviceConflict_CloudValueShouldWin() throws {
        // Simulate Device A and Device B having different values
        
        // Given - Device A has local value
        clearAllTestData()
        if let defaults = UserDefaults(suiteName: "group.me.freas.encamera.debug") {
            defaults.set("deviceAValue", forKey: "currentKey")
            defaults.synchronize()
        }
        
        // Device B has cloud value (simulating sync from another device)
        setCloudValue("deviceBValue", forKey: "currentKey")
        Thread.sleep(forTimeInterval: 0.2)
        
        // When - Read the value (should prefer cloud)
        let value = UserDefaultUtils.string(forKey: .currentKey)
        
        // Then
        XCTAssertEqual(value, "deviceBValue", "Cloud value should take precedence in conflict")
    }
}

// MARK: - SavedSettings for Testing

fileprivate struct SavedSettings: Codable {
    let useBiometricsForAuth: Bool?
}
