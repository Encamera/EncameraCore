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
    let targetMedia: InteractableMedia<EncryptedMedia>
}

enum AppModal: Hashable {
    case galleryScrollView(context: GalleryScrollViewContext)
    case cameraView(context: CameraViewContext)
    case feedbackView
    case purchaseView(context: PurchaseViewContext)
}
