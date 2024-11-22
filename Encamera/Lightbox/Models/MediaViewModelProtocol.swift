//
//  MediaViewModelProtocol.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.24.
//
import EncameraCore

protocol MediaViewModelProtocol {
    init(sourceMedia: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, delegate: MediaViewingDelegate)
}
