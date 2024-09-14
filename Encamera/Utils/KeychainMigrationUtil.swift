//
//  KeychainMigrationUtil.swift
//  Encamera
//
//  Created by Alexander Freas on 14.09.24.
//

import Foundation
import EncameraCore

@MainActor
class KeychainMigrationUtil {

    private let keyManager: KeyManager
    private let keyForPrivateKey: String = "keyMigration"
    private let keyForPassphraseData: String = "passphraseMigration"

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    func prepareMigration() {
        do {
            guard let key = keyManager.currentKey else {
                debugPrint("No current active key")
                return
            }
            let data = try JSONEncoder().encode(key)

            UserDefaults.standard.set(data, forKey: keyForPrivateKey)
            
            let passphrase = try keyManager.retrieveKeyPassphrase()
            let passphraseData = try JSONEncoder().encode(passphrase)
            UserDefaults.standard.setValue(passphraseData, forKey: keyForPassphraseData)
        } catch {
            
        }
    }

    func completeMigration() {
        do {
            guard let keys = UserDefaults.standard.data(forKey: keyForPrivateKey) else {
                debugPrint("Could not get data for key")
                return
            }

            let key = try JSONDecoder().decode(PrivateKey.self, from: keys)
            try keyManager.save(key: key, setNewKeyToCurrent: true, backupToiCloud: false)

            guard let passphraseData = UserDefaults.standard.data(forKey: keyForPassphraseData) else {
                debugPrint("Could not get passphrase")
                return
            }

            let passphrase = try JSONDecoder().decode(KeyPassphrase.self, from: passphraseData)

            try keyManager.saveKeyWithPassphrase(passphrase: passphrase)
            EventTracking.trackKeyMigrationCompleted()
        } catch {

        }
    }


}
