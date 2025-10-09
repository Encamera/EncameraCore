//
//  KeychainMigrationUtil.swift
//  Encamera
//
//  Created by Alexander Freas on 14.09.24.
//

import Foundation
import EncameraCore

@MainActor
class KeychainMigrationUtil: DebugPrintable {

    private let keyManager: KeyManager
    private let keyForPrivateKey: String = "keyMigration"
    private let keyForPassphraseData: String = "passphraseMigration"
    private let keyForPasswordHash: String = "passwordHashMigration"
    private let keyForCompletedMigration: String = "completedMigration"
    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    func prepareMigration() {
        do {
            guard let key = keyManager.mainKey else {
                printDebug("No main key")
                return
            }
            printDebug("Keychain migration started")

            let data = try JSONEncoder().encode(key)
            UserDefaults.standard.set(data, forKey: keyForPrivateKey)
            printDebug("Migration: Set key data")
            let passphrase = try keyManager.retrieveKeyPassphrase()
            let passphraseData = try JSONEncoder().encode(passphrase)
            UserDefaults.standard.setValue(passphraseData, forKey: keyForPassphraseData)
            printDebug("Migration: Set passphrase data")

            let passwordHash = try keyManager.getPasswordHash()
            UserDefaults.standard.setValue(passwordHash, forKey: keyForPasswordHash)
            printDebug("Migration: Set password hash data")

            EventTracking.trackKeyMigrationPrepared()
        } catch {
            printDebug("Error pulling data \(error)")
        }
    }

    func completeMigration() {

        guard !UserDefaults.standard.bool(forKey: keyForCompletedMigration) else {
            return
        }

        var completedWithoutError = true

        do {
            if let passphraseData = UserDefaults.standard.data(forKey: keyForPassphraseData) {

                let passphrase = try JSONDecoder().decode(KeyPassphrase.self, from: passphraseData)

                try keyManager.saveKeyWithPassphrase(passphrase: passphrase)
                UserDefaults.standard.set(nil, forKey: keyForPassphraseData)
                UserDefaults.standard.set(nil, forKey: keyForPrivateKey)
                printDebug("Passphrase migration completed")
            } else if let keys = UserDefaults.standard.data(forKey: keyForPrivateKey),
                      UserDefaults.standard.data(forKey: keyForPassphraseData) == nil {
                printDebug("Could not get data for key")


                let key = try JSONDecoder().decode(PrivateKey.self, from: keys)
                try keyManager.save(key: key, setNewKeyAsMain: true)
                UserDefaults.standard.set(nil, forKey: keyForPrivateKey)
                printDebug("Keychain migration completed")
            }

        } catch {
            printDebug("Could not migrate passphrase data: \(error)")
            completedWithoutError = false
        }

        do {
            if let passwordHash = UserDefaults.standard.data(forKey: keyForPasswordHash) {

                try keyManager.setPasswordHash(hash: passwordHash)
                UserDefaults.standard.set(nil, forKey: keyForPasswordHash)
                printDebug("Keychain migration completed")
            }
        } catch {
            printDebug("Could not migrate password hash: \(error)")
            completedWithoutError = false
        }

        if completedWithoutError {
            EventTracking.trackKeyMigrationCompleted()
            UserDefaults.standard.set(true, forKey: keyForCompletedMigration)
        } else {
            EventTracking.trackKeyMigrationFailedWithError()
        }
    }
}
