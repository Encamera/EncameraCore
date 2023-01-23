//
//  FileProtocols.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine
import UIKit

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
    func loadLeadingThumbnail() async throws -> UIImage?
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel where T.MediaSource == URL
    func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<URL>
    func loadMediaInMemory<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<Data>
}

protocol FileWriter {
        
    @discardableResult func save<T: MediaSourcing>(media: CleartextMedia<T>) async throws -> EncryptedMedia
    @discardableResult func savePreview<T: MediaDescribing>(preview: PreviewModel, sourceMedia: T) async throws -> CleartextMedia<Data>
    func copy(media: EncryptedMedia) async throws
    func delete(media: EncryptedMedia) async throws
    func deleteMedia(for key: PrivateKey) async throws
    func moveAllMedia(for keyName: KeyName, toRenamedKey newKeyName: KeyName) async throws
    func deleteAllMedia() async throws
}

protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    init()
}

extension FileAccess {
    var operationBus: FileOperationBus {
        FileOperationBus.shared
    }
}
