//
//  AppModal.swift
//  Encamera
//
//  Created by Alexander Freas on 27.01.25.
//

import Foundation
import EncameraCore

protocol ModalContext: Hashable {
    var sourceView: String { get }
}

struct CameraViewContext: ModalContext {

    static func == (lhs: CameraViewContext, rhs: CameraViewContext) -> Bool {
        lhs.album == rhs.album
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(album)
    }
    let sourceView: String
    let album: Album?
    var closeButtonTapped: (_ targetAlbum: Album?) -> Void
    init(sourceView: String, album: Album? = nil, closeButtonTapped: @escaping (_: Album?) -> Void) {
        self.sourceView = sourceView
        self.closeButtonTapped = closeButtonTapped
        self.album = album
    }
}

struct PurchaseViewContext: ModalContext {

    static func == (lhs: PurchaseViewContext, rhs: PurchaseViewContext) -> Bool {
        return lhs.sourceView == rhs.sourceView
    }

    let sourceView: String

    let purchaseAction: PurchaseResultAction?

    func hash(into hasher: inout Hasher) {
        hasher.combine(sourceView)
    }
}

struct GalleryScrollViewContext: ModalContext {
    let sourceView: String
    let media: [InteractableMedia<EncryptedMedia>]
    let album: Album?
    let targetMedia: InteractableMedia<EncryptedMedia>
}

struct AlbumSelectionContext: ModalContext {
    let sourceView: String
    let availableAlbums: [Album]
    let currentAlbum: Album
    let selectedMedia: Set<InteractableMedia<EncryptedMedia>>
    let onAlbumSelected: (Album) -> Void
    let onDismiss: () -> Void
    
    static func == (lhs: AlbumSelectionContext, rhs: AlbumSelectionContext) -> Bool {
        return lhs.currentAlbum.id == rhs.currentAlbum.id && lhs.selectedMedia == rhs.selectedMedia
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(currentAlbum.id)
        hasher.combine(selectedMedia)
    }
}

struct AddAlbumModalContext: ModalContext {
    let sourceView: String
    let onAlbumCreated: (Album) -> Void
    let onDismiss: () -> Void
    
    static func == (lhs: AddAlbumModalContext, rhs: AddAlbumModalContext) -> Bool {
        return lhs.sourceView == rhs.sourceView
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(sourceView)
    }
}

enum AppModal: Hashable {
    case galleryScrollView(context: GalleryScrollViewContext)
    case cameraView(context: CameraViewContext)
    case feedbackView
    case purchaseView(context: PurchaseViewContext)
    case albumSelection(context: AlbumSelectionContext)
    case addAlbum(context: AddAlbumModalContext)
}
