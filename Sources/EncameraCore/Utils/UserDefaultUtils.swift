//
//  UserDefaultUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation
import Combine

public final class UserDefaultUtils: DebugPrintable {

    #if DEBUG
    public static var appGroup = "group.me.freas.encamera.debug"
    #else
    public static var appGroup = "group.me.freas.encamera"
    #endif

    // MARK: - Replaceable shared instance

    public static var current = UserDefaultUtils()

    // MARK: - Instance state

    public let defaults: UserDefaults
    public var writesAreBlockedForErase = false

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.appGroup) ?? UserDefaults.standard
    }

    // MARK: - Constants

    private static let iCloudMigrationKey = "DidMigrateToiCloud_v1"

    // MARK: - iCloud (process-wide singletons)

    private static var cloudStore: NSUbiquitousKeyValueStore {
        NSUbiquitousKeyValueStore.default
    }

    private static var iCloudObserver: NSObjectProtocol?
    private static var defaultsSubject = PassthroughSubject<(UserDefaultKey, Any?), Never>()
    private static var iCloudKeysChangedSubject = PassthroughSubject<[String], Never>()

    private static var defaultsPublisher: AnyPublisher<(UserDefaultKey, Any?), Never> {
        defaultsSubject.eraseToAnyPublisher()
    }

    public static var iCloudKeysChangedPublisher: AnyPublisher<[String], Never> {
        iCloudKeysChangedSubject.eraseToAnyPublisher()
    }

    // MARK: - iCloud setup / teardown

    public static func setupiCloudSync() {
        iCloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { notification in
            handleiCloudChange(notification)
        }

        for key in localOnlyMarkerKeys where cloudStore.object(forKey: key) != nil {
            cloudStore.removeObject(forKey: key)
        }

        cloudStore.synchronize()
        printDebug("[UserDefaultUtils] iCloud sync initialized")
    }

    public static func tearDowniCloudSync() {
        if let observer = iCloudObserver {
            NotificationCenter.default.removeObserver(observer)
            iCloudObserver = nil
        }
    }

    // MARK: - iCloud change handling

    private static func handleiCloudChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        if let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int {
            switch changeReason {
            case NSUbiquitousKeyValueStoreServerChange,
                 NSUbiquitousKeyValueStoreInitialSyncChange:
                break
            case NSUbiquitousKeyValueStoreQuotaViolationChange:
                printDebug("[UserDefaultUtils] WARNING: iCloud quota violation")
                return
            case NSUbiquitousKeyValueStoreAccountChange:
                printDebug("[UserDefaultUtils] iCloud account changed - resyncing")
            default:
                break
            }
        }

        if let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
            let inst = current
            for keyString in changedKeys where !localOnlyMarkerKeys.contains(keyString) {
                if inst.writesAreBlockedForErase { break }
                if let value = cloudStore.object(forKey: keyString) {
                    inst.defaults.set(value, forKey: keyString)
                    printDebug("[UserDefaultUtils] Synced from iCloud: \(keyString)")
                    defaultsSubject.send((UserDefaultKey.savedSettings, value))
                }
            }
            if !changedKeys.isEmpty {
                iCloudKeysChangedSubject.send(changedKeys)
            }
        }
    }

    // MARK: - Instance methods (the real implementations)

    public func _set(_ value: Any?, forKey key: UserDefaultKey) {
        let keyString = key.rawValue
        guard !_isWriteRefusedAfterErase(keyString) else { return }

        defaults.set(value, forKey: keyString)

        if key.shouldSyncToiCloud {
            if let value = value {
                Self.cloudStore.set(value, forKey: keyString)
                Self.cloudStore.synchronize()
                printDebug("[UserDefaultUtils] Set to iCloud: \(keyString)")
            } else {
                Self.cloudStore.removeObject(forKey: keyString)
                Self.cloudStore.synchronize()
                printDebug("[UserDefaultUtils] Removed from iCloud: \(keyString)")
            }
        }

        Self.defaultsSubject.send((key, value))
    }

    public func _value(forKey key: UserDefaultKey) -> Any? {
        defaults.value(forKey: key.rawValue)
    }

    public func _integer(forKey key: UserDefaultKey) -> Int {
        defaults.integer(forKey: key.rawValue)
    }

    public func _string(forKey key: UserDefaultKey) -> String? {
        defaults.string(forKey: key.rawValue)
    }

    public func _boolNullable(forKey key: UserDefaultKey) -> Bool? {
        if defaults.object(forKey: key.rawValue) == nil { return nil }
        return defaults.bool(forKey: key.rawValue)
    }

    public func _bool(forKey key: UserDefaultKey) -> Bool {
        _boolNullable(forKey: key) ?? false
    }

    public func _removeObject(forKey key: UserDefaultKey) {
        let keyString = key.rawValue
        guard !_isWriteRefusedAfterErase(keyString) else { return }

        defaults.removeObject(forKey: keyString)

        if key.shouldSyncToiCloud {
            Self.cloudStore.removeObject(forKey: keyString)
            Self.cloudStore.synchronize()
            printDebug("[UserDefaultUtils] Removed from iCloud: \(keyString)")
        }

        Self.defaultsSubject.send((key, nil))
    }

    public func _dictionary(forKey key: UserDefaultKey) -> [String: Any]? {
        defaults.dictionary(forKey: key.rawValue)
    }

    public func _data(forKey key: UserDefaultKey) -> Data? {
        defaults.data(forKey: key.rawValue)
    }

    /// Keeps `pendingCloudDataWipe`: a cloud wipe owed by an earlier erase is
    /// still owed after this one.
    public func _removeAll(setTombstone: Bool) {
        defaults.dictionaryRepresentation().keys
            .filter { $0 != UserDefaultKey.pendingCloudDataWipe.rawValue }
            .forEach { key in
                defaults.removeObject(forKey: key)
            }

        let cloudDict = Self.cloudStore.dictionaryRepresentation
        cloudDict.keys.forEach { key in
            Self.cloudStore.removeObject(forKey: key)
        }
        _set(setTombstone, forKey: .pendingDefaultsWipe)
        Self.cloudStore.synchronize()
        defaults.synchronize()
    }

    public func _flushPendingWrites() {
        defaults.synchronize()
        UserDefaults.standard.synchronize()
        var domains = [Self.appGroup]
        if let bundleID = Bundle.main.bundleIdentifier {
            domains.append(bundleID)
        }
        for domain in domains {
            CFPreferencesAppSynchronize(domain as CFString)
            CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
    }

    public func _blockWritesForErase() {
        writesAreBlockedForErase = true
    }

    private func _isWriteRefusedAfterErase(_ keyString: String) -> Bool {
        guard writesAreBlockedForErase, !Self.localOnlyMarkerKeys.contains(keyString) else { return false }
        printDebug("[UserDefaultUtils] Refused post-erase write: \(keyString)")
        return true
    }

    public func _checkTombstoneAndWipe() {
        guard _bool(forKey: .pendingDefaultsWipe) else { return }
        let keep: Set<String> = [UserDefaultKey.pendingCloudDataWipe.rawValue]
        if let domain = defaults.persistentDomain(forName: Self.appGroup) {
            for key in domain.keys where !keep.contains(key) {
                defaults.removeObject(forKey: key)
            }
        }
        if let bundleID = Bundle.main.bundleIdentifier,
           let domain = UserDefaults.standard.persistentDomain(forName: bundleID) {
            for key in domain.keys where !keep.contains(key) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        _flushPendingWrites()
    }

    public func _encameraOwnedKeysStillSet() -> [String] {
        var keys = Set<String>()

        if let groupDefaults = UserDefaults(suiteName: Self.appGroup),
           let domain = groupDefaults.persistentDomain(forName: Self.appGroup) {
            keys.formUnion(domain.keys)
        }
        if let bundleID = Bundle.main.bundleIdentifier,
           let domain = UserDefaults.standard.persistentDomain(forName: bundleID) {
            keys.formUnion(domain.keys)
        }
        keys.formUnion(Self.cloudStore.dictionaryRepresentation.keys)

        return keys.filter { key in
            !Self.systemOwnedDefaultsPrefixes.contains { key.hasPrefix($0) }
        }
    }

    public func _needsiCloudMigration() -> Bool {
        !defaults.bool(forKey: Self.iCloudMigrationKey)
    }

    public func _migrateToiCloudStorage() {
        guard _needsiCloudMigration() else {
            printDebug("[UserDefaultUtils] iCloud migration already completed")
            return
        }

        printDebug("[UserDefaultUtils] Starting iCloud migration...")

        var migratedCount = 0

        for key in Self.syncableKeys {
            let keyString = key.rawValue
            guard let value = defaults.value(forKey: keyString) else { continue }

            if Self.cloudStore.object(forKey: keyString) == nil {
                Self.cloudStore.set(value, forKey: keyString)
                migratedCount += 1
                printDebug("[UserDefaultUtils] Migrated to iCloud: \(keyString)")
            } else if let cloudValue = Self.cloudStore.object(forKey: keyString) {
                defaults.set(cloudValue, forKey: keyString)
                printDebug("[UserDefaultUtils] Synced from iCloud: \(keyString)")
            }
        }

        Self.cloudStore.synchronize()

        defaults.set(true, forKey: Self.iCloudMigrationKey)
        defaults.synchronize()

        printDebug("[UserDefaultUtils] iCloud migration completed. Migrated \(migratedCount) keys.")
    }

    // MARK: - Static constants

    static let localOnlyMarkerKeys: Set<String> = [
        UserDefaultKey.pendingDefaultsWipe.rawValue,
        UserDefaultKey.pendingCloudDataWipe.rawValue,
    ]

    static let systemOwnedDefaultsPrefixes = [
        "Apple", "NS", "com.apple.", "AK", "ACD", "PK", "INNext", "MSV", "WebKit",
        "AddingEmojiKeybord", "shouldShowRSVPDataDetectors"
    ]

    private static let syncableKeys: [UserDefaultKey] = [
        .onboardingState, .savedSettings, .currentAlbumID, .showCurrentAlbumOnLaunch,
        .keyTutorialClosed, .hasOpenedAlbum, .defaultStorageLocation, .livePhotosActivated,
        .gridZoomLevel, .gridSortOption, .currentKey,
        .hasBeenShownHideAlbumTutorial
    ]

    // MARK: - Static delegation (zero changes to production call sites)

    public static func increaseInteger(forKey key: UserDefaultKey) {
        var currentValue = value(forKey: key) as? Int ?? 0
        currentValue += 1
        set(currentValue, forKey: key)
    }

    public static func increaseInteger(forKey key: UserDefaultKey, by number: Int) {
        var currentValue = value(forKey: key) as? Int ?? 0
        currentValue += number
        set(currentValue, forKey: key)
    }

    public static func publisher(for observedKey: UserDefaultKey) -> AnyPublisher<Any?, Never> {
        defaultsPublisher.filter { key, _ in observedKey == key }
            .map { _, value in value }
            .share()
            .eraseToAnyPublisher()
    }

    public static func integer(forKey key: UserDefaultKey) -> Int { current._integer(forKey: key) }
    public static func string(forKey key: UserDefaultKey) -> String? { current._string(forKey: key) }
    public static func set(_ value: Any?, forKey key: UserDefaultKey) { current._set(value, forKey: key) }
    public static func value(forKey key: UserDefaultKey) -> Any? { current._value(forKey: key) }
    public static func boolNullable(forKey key: UserDefaultKey) -> Bool? { current._boolNullable(forKey: key) }
    public static func bool(forKey key: UserDefaultKey) -> Bool { current._bool(forKey: key) }
    public static func removeObject(forKey key: UserDefaultKey) { current._removeObject(forKey: key) }
    public static func dictionary(forKey key: UserDefaultKey) -> [String: Any]? { current._dictionary(forKey: key) }
    public static func data(forKey key: UserDefaultKey) -> Data? { current._data(forKey: key) }
    public static func removeAll(setTombstone: Bool) { current._removeAll(setTombstone: setTombstone) }
    public static func flushPendingWrites() { current._flushPendingWrites() }
    public static func blockWritesForErase() { current._blockWritesForErase() }
    public static func checkTombstoneAndWipe() { current._checkTombstoneAndWipe() }
    public static func encameraOwnedKeysStillSet() -> [String] { current._encameraOwnedKeysStillSet() }
    public static func needsiCloudMigration() -> Bool { current._needsiCloudMigration() }
    public static func migrateToiCloudStorage() { current._migrateToiCloudStorage() }

    public static func migrateUserDefaultsToAppGroups() {
        let userDefaults = UserDefaults.standard
        let groupDefaults = UserDefaults(suiteName: appGroup)
        let didMigrateToAppGroups = "DidMigrateToAppGroups"

        if let groupDefaults = groupDefaults {
            if !groupDefaults.bool(forKey: didMigrateToAppGroups) {
                for (key, value) in userDefaults.dictionaryRepresentation() {
                    groupDefaults.set(value, forKey: key)
                }
                groupDefaults.set(true, forKey: didMigrateToAppGroups)
                groupDefaults.synchronize()
                printDebug("Successfully migrated defaults to app groups")
            } else {
                printDebug("No need to migrate defaults to app groups")
            }
        } else {
            printDebug("Unable to create NSUserDefaults with given app group")
        }
    }
}

public extension UserDefaultUtils {

    static func resetReviewMetric() {
        Self.set(0, forKey: .reviewRequestedMetric)
    }
}
