//
//  Navigation.swift
//  Encamera
//
//  Created by Alexander Freas on 15.09.24.
//

import Foundation
import EncameraCore

struct GalleryScrollViewContext: Hashable {
    let media: [InteractableMedia<EncryptedMedia>]
    let targetMedia: InteractableMedia<EncryptedMedia>
}

enum AppNavigationPaths: Hashable {

    case createAlbum
    case albumDetail(album: Album)
}

enum AppModal: Hashable {
    case galleryScrollView(context: GalleryScrollViewContext)
    case cameraView
    case feedbackView
}
