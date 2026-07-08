//
//  LegacyAuthenticationSettingsMigration.swift
//  Encamera
//
//  One-time migration of the authentication method from the deleted
//  SettingsManager's UserDefaults blob (.savedSettings) into the keychain-backed
//  AuthenticationConfiguration. Without this, existing users who had biometrics
//  enabled would silently lose it after updating.
//

import Foundation

public struct LegacyAuthenticationSettingsMigration {

    /// Shape of the old SettingsManager's SavedSettings JSON stored under .savedSettings.
    private struct LegacySavedSettings: Codable {
        var useBiometricsForAuth: Bool?
    }

    public static func migrateIfNeeded(keyManager: KeyManager) {
        // Already migrated (or freshly onboarded) — the keychain is the source of truth.
        guard keyManager.getAuthenticationConfiguration() == nil else {
            return
        }

        let legacyBiometrics: Bool?
        if let data = UserDefaultUtils.data(forKey: .savedSettings),
           let legacy = try? JSONDecoder().decode(LegacySavedSettings.self, from: data) {
            legacyBiometrics = legacy.useBiometricsForAuth
        } else {
            legacyBiometrics = nil
        }

        let passwordExists = keyManager.passwordExists()

        // Fresh install that hasn't onboarded yet: nothing to migrate,
        // onboarding will write the configuration.
        guard legacyBiometrics != nil || passwordExists else {
            return
        }

        var config = AuthenticationConfiguration(enabledTypes: [])
        if legacyBiometrics == true {
            config.addAuthenticationType(.biometrics)
        }
        if passwordExists {
            let passcodeType = keyManager.passcodeType
            config.addAuthenticationType(.passcode(passcodeType))
        }

        do {
            try keyManager.setAuthenticationConfiguration(config: config)
            UserDefaultUtils.removeObject(forKey: .savedSettings)
        } catch {
            // Keep the legacy value so the migration retries on next launch.
            debugPrint("LegacyAuthenticationSettingsMigration: could not write configuration: \(error)")
        }
    }
}
