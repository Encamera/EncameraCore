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
    var albumManager: AlbumManaging?
    var album: Album?
    var currentSharingData: Any?
    var purchaseButtonPressed: () -> (Void)
    var reviewAlertActionPressed: (AskForReviewUtil.ReviewSelection) -> (Void)
    var albumCoverSetAction: (InteractableMedia<EncryptedMedia>) -> (Void)
    private var cancellables = Set<AnyCancellable>()

    @Published var viewOffsets: [UUID: CGFloat] = [:]
    init(media: [InteractableMedia<EncryptedMedia>],
         initialMedia: InteractableMedia<EncryptedMedia>,
         fileAccess: FileAccess,
         album: Album? = nil,
         albumManager: AlbumManaging? = nil,
         showActionBar: Bool = true,
         purchasedPermissions: PurchasedPermissionManaging,
         purchaseButtonPressed: @escaping () -> (Void),
         reviewAlertActionPressed: @escaping (AskForReviewUtil.ReviewSelection) -> (Void),
         albumCoverSetAction: @escaping (InteractableMedia<EncryptedMedia>) -> (Void)) {
        self.reviewAlertActionPressed = reviewAlertActionPressed
        self.purchaseButtonPressed = purchaseButtonPressed
        self.media = media
        self.album = album
        self.albumManager = albumManager
        self.fileAccess = fileAccess
        self.initialMedia = initialMedia
        self.showActionBar = showActionBar
        self.purchasedPermissions = purchasedPermissions
        self.selectedMedia = initialMedia
        self.albumCoverSetAction = albumCoverSetAction
        super.init()
        updateMediaMap()
    }
}
