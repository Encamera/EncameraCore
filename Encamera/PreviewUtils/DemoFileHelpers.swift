//
//  File.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import UIKit
import Combine
import Sodium

enum DemoError: Error {
    case general
}

class DemoFileEnumerator: FileAccess {
    required init() {
        guard let url = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg"),
              let dog = Bundle(for: type(of: self)).url(forResource: "dog", withExtension: "jpg") else {
            return
        }
        
        mediaList = (0..<5).map { val in
            EncryptedMedia(source: url, mediaType: .photo, id: "\(NSUUID().uuidString)")
        }
        
        
        
        mediaList += (6..<10).map { val in
            EncryptedMedia(source: dog, mediaType: .photo, id: "\(NSUUID().uuidString)")
        }
        
        mediaList.shuffle()
    }
    
    func configure(with key: PrivateKey?, storageSettingsManager: DataStorageSetting) async {
        
    }
    
    
    func copy(media: EncryptedMedia) async throws {
        
    }
    
    var mediaList: [EncryptedMedia] = []
    
    func savePreview<T>(preview: PreviewModel, sourceMedia: T) async throws -> CleartextMedia<Data> where T : MediaDescribing {
        fatalError()
    }
    func loadThumbnails<T>(for: DataStorageModel) async -> [T] where T : MediaDescribing, T.MediaSource == Data {
        []
    }
    
    func deleteMedia(for key: PrivateKey) async throws {
        
    }
    
    func moveAllMedia(for keyName: KeyName, toRenamedKey newKeyName: KeyName) async throws {
        
    }
    
    func loadMediaToURL<T>(media: T, progress: (Double) -> Void) async throws -> CleartextMedia<URL> where T : MediaDescribing {

        CleartextMedia(source: URL(fileURLWithPath: ""))
    }
    
    func loadMediaInMemory<T>(media: T, progress: (Double) -> Void) async throws -> CleartextMedia<Data> where T : MediaDescribing {
        let url = Bundle(for: type(of: self)).url(forResource: "dog", withExtension: "jpg")!

        return CleartextMedia(source: try! Data(contentsOf: url))
    }
    
    func save<T>(media: CleartextMedia<T>) async throws -> EncryptedMedia where T : MediaSourcing {
        EncryptedMedia(source: URL(fileURLWithPath: ""), mediaType: .photo, id: "1234")
    }
    
    func loadMediaPreview<T: MediaDescribing>(for media: T) async -> PreviewModel {
        let source = media.source as! URL
        let data = try! Data(contentsOf: source)
        let cleartext = CleartextMedia<Data>(source: data)
        var preview = PreviewModel(thumbnailMedia: cleartext)
        preview.videoDuration = "0:34"
        return preview
//        let source = media.source as! URL
//        let data = try! Data(contentsOf: source)
//        return CleartextMedia<Data>(source: data)
    }
    
    func createTempURL(for mediaType: MediaType, id: String) -> URL {
        return URL(fileURLWithPath: "")
    }

    
    
    typealias MediaTypeHandling = Data
    
    
    let directoryModel = DemoDirectoryModel()
    
    
    
    func enumerateMedia<T>() async -> [T] where T : MediaDescribing, T.MediaSource == URL {
         
        let url = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        
        var retVal = (0..<5).map { val in
            T(source: url, mediaType: .photo, id: "\(val)")
        }
        
        let dog = Bundle(for: type(of: self)).url(forResource: "dog", withExtension: "jpg")!
        
        retVal += (0..<5).map { val in
            T(source: dog, mediaType: .photo, id: "\(val)")
        }
        
        return retVal.shuffled()
    }
    func delete(media: EncryptedMedia) async throws {
        
    }
    func deleteAllMedia() async throws {
        
    }
}

class DemoDirectoryModel: DataStorageModel {
    var storageType: StorageType = .local
    
    var keyName: KeyName = "testSuite"
    
    var baseURL: URL
    
    var thumbnailDirectory: URL
    
    required init(keyName: KeyName) {
        self.baseURL = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true).appendingPathComponent("base")
        self.thumbnailDirectory = URL(fileURLWithPath: NSTemporaryDirectory(),
                                      isDirectory: true).appendingPathComponent("thumbs")
    }
    
    convenience init() {
        self.init(keyName: "")
    }
    
    
    func deleteAllFiles() throws {
       try  [baseURL, thumbnailDirectory].forEach { url in
            guard let enumerator = FileManager.default.enumerator(atPath: url.path) else {
                return
            }
            try enumerator.compactMap { item in
                guard let itemUrl = item as? URL else {
                    return nil
                }
                return itemUrl
            }
            .forEach { (file: URL) in
                try FileManager.default.removeItem(at: file)
                debugPrint("Deleted file at \(file)")
            }
        }
    }
        
}

class DemoKeyManager: KeyManager {
    
    var keyDirectoryStorage: DataStorageSetting = DemoStorageSettingsManager()
    
     
    
    private var hasExistingPassword = false
    var throwError = false
    var password: String? {
        didSet {
            hasExistingPassword = password != nil
        }
    }
    func createBackupDocument() throws -> String {
        return ""
    }
    func passwordExists() -> Bool {
        return hasExistingPassword
    }
    
    func validate(password: String) -> PasswordValidation {
        return .valid
    }
    
    func changePassword(newPassword: String, existingPassword: String) throws {
        
    }
    
    func checkPassword(_ password: String) throws -> Bool {
        if self.password != password {
            throw KeyManagerError.invalidPassword
        }
        return self.password == password
    }
    
    func setPassword(_ password: String) throws {
        self.password = password
    }
    
    func deleteKey(_ key: PrivateKey) throws {
        
    }
    
    func save(key: PrivateKey, storageType: StorageType) throws {
        
    }
    
    var currentKey: PrivateKey?
    
    func setActiveKey(_ name: KeyName?) throws {
        
    }
    
    
    var storedKeysValue: [PrivateKey] = []
    
    func deleteKey(by name: KeyName) throws {
        
    }
    
    func setActiveKey(_ name: KeyName) throws {
        
    }
    
    func generateNewKey(name: String, storageType: StorageType) throws -> PrivateKey {
        return try PrivateKey(base64String: "")
    }
    
    func storedKeys() throws -> [PrivateKey] {
        return storedKeysValue
    }
    
    func validateKeyName(name: String) throws {
        
    }
    
    
    convenience init() {
        self.init(isAuthenticated: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager())
    }
    
    required init(isAuthenticated: AnyPublisher<Bool, Never>, keyDirectoryStorage: DataStorageSetting) {
        self.isAuthenticated = isAuthenticated
        self.currentKey = PrivateKey(name: "test", keyBytes: [], creationDate: Date())
        self.keyPublisher = PassthroughSubject<PrivateKey?, Never>().eraseToAnyPublisher()
    }
    
    var isAuthenticated: AnyPublisher<Bool, Never>
        
    var keyPublisher: AnyPublisher<PrivateKey?, Never>
    
    func clearKeychainData() throws {
        
    }
    
    func generateNewKey(name: String) throws {
        
    }
    
    func validatePasswordPair(_ password1: String, password2: String) -> PasswordValidation {
        return .valid
    }
}

class DemoOnboardingManager: OnboardingManaging {
    required init(keyManager: KeyManager, authManager: AuthManager, settingsManager: SettingsManager) {
        
    }
    
    func generateOnboardingFlow() -> [OnboardingFlowScreen] {
        return [.setupPrivateKey, .dataStorageSetting]
    }
    
    func saveOnboardingState(_ state: OnboardingState, settings: SavedSettings) async throws {
        
    }
    
    
}

class DemoStorageSettingsManager: DataStorageSetting {
    
    func storageModelFor(keyName: KeyName?) -> DataStorageModel? {
        return LocalStorageModel(keyName: keyName!)
    }
    
    func setStorageTypeFor(keyName: KeyName, directoryModelType: StorageType) {
        
    }
    
    
}

class DemoPrivateKey {
    
    static func dummyKey() -> PrivateKey {
        let hash: Array<UInt8> = [36,97,114,103,111,110,50,105,100,36,118,61,49,57,36,109,61,54,53,53,51,54,44,116,61,50,44,112,61,49,36,76,122,73,48,78,103,67,57,90,69,89,76,81,80,70,76,85,49,69,80,119,65,36,83,66,66,49,65,85,86,74,55,82,85,90,116,79,67,111,104,82,100,89,67,71,57,114,90,119,109,81,47,118,74,77,121,48,85,71,108,69,103,66,122,79,77]
        let dateComponents = DateComponents(timeZone: TimeZone(identifier: "gmt"), year: 2022, month: 2, day: 9, hour: 5, minute: 0, second: 0)
        let date = Calendar(identifier: .gregorian).date(from: dateComponents)
        print("date", date!)
        return PrivateKey(name: "test", keyBytes: hash, creationDate: date!)
    }
}
