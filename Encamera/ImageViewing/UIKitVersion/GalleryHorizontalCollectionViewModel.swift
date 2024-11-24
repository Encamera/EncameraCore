//
//  GalleryHorizontalCollectionViewModel.swift
//  Encamera
//
//  Created by Alexander Freas on 15.11.24.
//

import Foundation
import SwiftUI
import Combine
import EncameraCore

@MainActor
class GalleryHorizontalCollectionViewModel: NSObject, ObservableObject, DebugPrintable {

    @Published var media: [InteractableMedia<EncryptedMedia>] {
        didSet {
            updateMediaMap()
        }
    }

    func updateMediaMap() {
        let map = media.reduce(into: [:]) { result, media in
            result[media.id] = media
        }
        mediaMap = map
    }
    var mediaMap: [String: InteractableMedia<EncryptedMedia>] = [:]
    var selectedMedia: InteractableMedia<EncryptedMedia>?
    var selectedMediaPreview: PreviewModel?
    var initialMedia: InteractableMedia<EncryptedMedia>?
    var showInfoSheet = false
    var showPurchaseSheet = false
    var isPlayingVideo = false
    var isPlayingLivePhoto = false
    var lastProcessedValues = Set<CGFloat>()
    var purchasedPermissions: PurchasedPermissionManaging
    var showActionBar = true
    var fileAccess: FileAccess
    var currentSharingData: Any?
    private var cancellables = Set<AnyCancellable>()
    @Published var viewOffsets: [UUID: CGFloat] = [:]
    init(media: [InteractableMedia<EncryptedMedia>], initialMedia: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, showActionBar: Bool = true, purchasedPermissions: PurchasedPermissionManaging) {

        self.media = media
        self.fileAccess = fileAccess
        self.initialMedia = initialMedia
        self.showActionBar = showActionBar
        self.purchasedPermissions = purchasedPermissions
        self.selectedMedia = initialMedia
        super.init()
        updateMediaMap()
    }
}
