//
//  MediaViewModelProtocol.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.24.
//
import EncameraCore

protocol MediaViewModelProtocol {
    init(sourceMedia: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, delegate: MediaViewingDelegate, pageIndex: Int)
    var sourceMedia: InteractableMedia<EncryptedMedia> { get }
    var decryptedFileRef: InteractableMedia<CleartextMedia>? { get }
    var pageIndex: Int { get set }
    
    func decryptAndSet()
}
