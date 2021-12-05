//
//  ChaChaPolyHelper.swift
//  sNotes
//
//  Created by Sergey Sedov on 13.06.2021.
//  Copyright © 2021 Apple. All rights reserved.
//

import CryptoKit
import UIKit

struct ChaChaPolyHelpers {
    
    //MARK:- ENCRYPT
    static func encrypt(contentData: Data?) -> Data? {
        guard let contentData = contentData else {
            return nil
        }
        guard let encryptionKey = getKey() else { return nil }
        guard let combined = try? ChaChaPoly.seal(contentData, using: encryptionKey).combined  else {
            return nil
        }
        return combined.base64EncodedData()
    }
    
    static func encrypt(string: String?) -> Data? {
        guard let string = string else {
            return nil
        }
        guard let encryptionKey = getKey() else { return nil }
        guard let contentData = string.data(using: .utf8) else { return nil}
        guard let combined = try? ChaChaPoly.seal(contentData, using: encryptionKey).combined  else {
            return nil
        }
        return combined.base64EncodedData()
    }
    
    static func encrypt(image: UIImage?) -> Data? {
        guard let image = image else {
            return nil
        }
        guard let encryptionKey = getKey() else { return nil }
        guard let contentData = image.pngData() else {
            return nil
        }
        do {
            let combined = try ChaChaPoly.seal(contentData, using: encryptionKey).combined
            return combined.base64EncodedData()

        } catch {
            print(error.localizedDescription)
            return nil
        }
    }


    //MARK:- DECRYPT
    static func decrypt(encryptedContent: Data?) -> Data? {
        guard let encryptionKey = getKey() else { return nil }
        guard let encryptedContent = encryptedContent else {
            return nil
        }
        guard let content = Data(base64Encoded: encryptedContent) else {
            return nil
        }
        guard let sealedBox = try? ChaChaPoly.SealedBox(combined: content), let data = try? ChaChaPoly.open(sealedBox, using: encryptionKey) else {
            return nil
        }
        return data
    }
    
    static func decrypt(encryptedContent: Data?) -> String? {
        guard let encryptionKey = getKey() else { return nil }
       

        guard let encryptedContent = encryptedContent else {
            return nil
        }
        guard let content = Data(base64Encoded: encryptedContent) else {
            return nil
        }
        guard let sealedBox = try? ChaChaPoly.SealedBox(combined: content), let data = try? ChaChaPoly.open(sealedBox, using: encryptionKey) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    
    enum ChaChaPolyHelperError: Error {
        
    }

    static func decrypt(encryptedContent: Data?) -> UIImage? {
        guard let encryptionKey = getKey() else { return nil }
        guard let encryptedContent = encryptedContent else {
            return nil
        }
        guard let content = Data(base64Encoded: encryptedContent) else {
            return nil
        }
        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: content)
            let data = try ChaChaPoly.open(sealedBox, using: encryptionKey)

            return UIImage(data: data)
        } catch {
            
            print("error decrypting image", String(describing: error))
            return nil
        }
        
    }
    
    @discardableResult static func generateNewKey(name: String) throws -> SymmetricKey {
        WorkWithKeychain.clearKeychain()
        let key = createKey()
        let save = key.withUnsafeBytes {Data(Array($0))}
        let keyObject = ImageKey(keyData: save, name: name)
        WorkWithKeychain.setKey(key: keyObject)
        return key
    }
    
    private static func getKey() -> SymmetricKey? {
        if let keyData = WorkWithKeychain.getKey() {
            return SymmetricKey(data: keyData)
        }
        return nil
    }
    
    private static func createKey() -> SymmetricKey {
        return SymmetricKey(size: .bits256)
    }
}

