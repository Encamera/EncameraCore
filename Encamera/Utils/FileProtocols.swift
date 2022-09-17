//
//  FileProtocols.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine

enum FileAccessError: Error {
    case missingDirectoryModel
    case missingPrivateKey
}

protocol FileEnumerator {
    func configure(with key: PrivateKey?, storageSettingsManager: DataStorageSetting) async
    func enumerateMedia<T: MediaDescribing>() async -> [T] where T.MediaSource == URL
}

protocol FileReader {
    func configure(with key: PrivateKey?, storageSettingsManager: DataStorageSetting) async
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel where T.MediaSource == URL
    func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<URL>
    func loadMediaInMemory<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<Data>
}

protocol FileWriter {
        
    @discardableResult func save<T: MediaSourcing>(media: CleartextMedia<T>) async throws -> EncryptedMedia
    @discardableResult func savePreview<T: MediaDescribing>(preview: PreviewModel, sourceMedia: T) async throws -> CleartextMedia<Data>
    func delete(media: EncryptedMedia) async throws
}

protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    init()
}

extension FileAccess {
    var operationBus: FileOperationBus {
        FileOperationBus.shared
    }
}
