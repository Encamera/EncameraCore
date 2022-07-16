//
//  File.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import UIKit
import Combine

enum DemoError: Error {
    case general
}

class DemoFileEnumerator: FileAccess {
    
    var media: [EncryptedMedia]
    
    func savePreview<T>(preview: PreviewModel, sourceMedia: T) async throws -> CleartextMedia<Data> where T : MediaDescribing {
        fatalError()
    }
    func loadThumbnails<T>(for: DirectoryModel) async -> [T] where T : MediaDescribing, T.MediaSource == Data {
        []
    }
    
    func saveThumbnail<T>(data: Data, sourceMedia: T) async throws -> CleartextMedia<Data> where T : MediaDescribing {
        fatalError()
    }
    
    func loadMediaToURL<T>(media: T, progress: (Double) -> Void) async throws -> CleartextMedia<URL> where T : MediaDescribing {

        CleartextMedia(source: URL(fileURLWithPath: ""))
    }
    
    func loadMediaInMemory<T>(media: T, progress: (Double) -> Void) async throws -> CleartextMedia<Data> where T : MediaDescribing {
        CleartextMedia(source: Data())
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
    
    required init(key: ImageKey) {
        let url = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        
        media = (0..<5).map { val in
            EncryptedMedia(source: url, mediaType: .photo, id: "\(NSUUID().uuidString)")
        }
        
        let dog = Bundle(for: type(of: self)).url(forResource: "dog", withExtension: "jpg")!
        
        media += (6..<10).map { val in
            EncryptedMedia(source: dog, mediaType: .photo, id: "\(NSUUID().uuidString)")
        }
        
        media.shuffle()

    }
    
    convenience init() {
        self.init(key: ImageKey(name: "", keyBytes: [], creationDate: Date()))
    }
    
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
}

class DemoDirectoryModel: DirectoryModel {
    var keyName: KeyName = "testSuite"
    
    var baseURL: URL
    
    var thumbnailDirectory: URL
    
    required init(keyName: KeyName) {
        self.baseURL = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true).appendingPathExtension("base")
        self.thumbnailDirectory = URL(fileURLWithPath: NSTemporaryDirectory(),
                                      isDirectory: true).appendingPathExtension("thumbs")
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
                print("Deleted file at \(file)")
            }
        }
    }
        
}

class DemoKeyManager: KeyManager {
    
    var hasExistingPassword = false
    
    func passwordExists() throws -> Bool {
        return hasExistingPassword
    }
    func validate(password: String) -> PasswordValidation {
        return .valid
    }
    func changePassword(newPassword: String, existingPassword: String) throws {
        
    }
    
    func checkPassword(_ password: String) throws -> Bool {
        return true
    }
    
    func setPassword(_ password: String) throws {
        
    }
    
    func deleteKey(_ key: ImageKey) throws {
        
    }
    
    func save(key: ImageKey) throws {
        
    }
    
    var currentKey: ImageKey?
    
    func setActiveKey(_ name: KeyName?) throws {
        
    }
    
    
    var storedKeysValue: [ImageKey] = []
    
    func deleteKey(by name: KeyName) throws {
        
    }
    
    func setActiveKey(_ name: KeyName) throws {
        
    }
    
    func generateNewKey(name: String) throws -> ImageKey {
        return try ImageKey(base64String: "")
    }
    
    func storedKeys() throws -> [ImageKey] {
        return storedKeysValue
    }
    
    
    convenience init() {
        self.init(isAuthorized: Just(true).eraseToAnyPublisher())
    }
    
    required init(isAuthorized: AnyPublisher<Bool, Never>) {
        self.isAuthorized = isAuthorized
        self.currentKey = ImageKey(name: "test", keyBytes: [], creationDate: Date())
        self.keyPublisher = PassthroughSubject<ImageKey?, Never>().eraseToAnyPublisher()
    }
    
    var isAuthorized: AnyPublisher<Bool, Never>
        
    var keyPublisher: AnyPublisher<ImageKey?, Never>
    
    func clearStoredKeys() throws {
        
    }
    
    func generateNewKey(name: String) throws {
        
    }
    
    func validatePasswordPair(_ password1: String, password2: String) -> PasswordValidation {
        return .valid
    }
}
