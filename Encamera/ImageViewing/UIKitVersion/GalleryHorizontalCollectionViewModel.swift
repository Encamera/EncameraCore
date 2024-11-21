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
    @Published var selectedMedia: InteractableMedia<EncryptedMedia>?
    @Published var selectedMediaPreview: PreviewModel?
    @Published var initialMedia: InteractableMedia<EncryptedMedia>?
    @Published var showInfoSheet = false
    @Published var showPurchaseSheet = false
    @Published var isPlayingVideo = false
    @Published var isPlayingLivePhoto = false
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
        startObservingOffsets()
    }

    var selectedIndex: Int {
        guard let selectedMedia = selectedMedia else { return 0 }
        return media.firstIndex(of: selectedMedia) ?? 0
    }

    func startObservingOffsets() {
        $viewOffsets
            .sink { [weak self] values in
                guard let self = self else { return }
                let setValues = Set(values.values)
                self.lastProcessedValues = setValues
                for (id, minX) in values {
                    let viewFrame = minX
                    if viewFrame >= 0  {
                        let newSelection = self.mediaMap[id.uuidString]
                        if self.selectedMedia != newSelection {
                            self.selectedMedia = newSelection
                            loadThumbnailForActiveMedia()
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    func deleteAction() {
        let targetIndex = selectedIndex
        guard let targetMedia = selectedMedia else {
            debugPrint("No media selected for deletion")
            return
        }

        Task {


            do {
                try await fileAccess.delete(media: targetMedia)
                await MainActor.run {
                    _ = withAnimation {
                        media.remove(at: targetIndex)
                    }
                }
            } catch {
                debugPrint("Error deleting media", error)
            }
        }
    }
    var imageModels: [InteractableMedia<EncryptedMedia>.ID: ImageViewingViewModel] = [:]
    func modelForMedia(item: InteractableMedia<EncryptedMedia>) -> ImageViewingViewModel {
        if let model = imageModels[item.id] {
            return model
        } else {
            let model = ImageViewingViewModel(sourceMedia: item, fileAccess: fileAccess, delegate: self)
            imageModels[item.id] = model
            return model
        }

    }

    func loadThumbnailForActiveMedia() {
        guard let selectedMedia = selectedMedia else { return }
        Task {
            do {
                let thumbnail = try await fileAccess.loadMediaPreview(for: selectedMedia)
                selectedMediaPreview = thumbnail
            } catch {
                debugPrint("Error loading thumbnail", error)
            }
        }
    }
    func shareDecrypted() {
        Task {
            guard let selectedMedia else { return }
            let sharingUtil = ShareMediaUtil(fileAccess: self.fileAccess, targetMedia: [selectedMedia])
            do {
                try await sharingUtil.prepareSharingData { status in
                    debugPrint("Status: \(status)")
                }
            } catch {
                debugPrint("Error: \(error)")
            }
            Task { @MainActor in
                do {
                    try await sharingUtil.showShareSheet()
                } catch {
                    printDebug("Error showing share sheet", error)
                }
            }
        }
    }


    func canAccessPhoto(at index: Int) -> Bool {
        return purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: Double(media.count - index)))
    }

    func showPurchaseScreen() {
        showPurchaseSheet = true
    }
}

extension GalleryHorizontalCollectionViewModel: MediaViewingDelegate {
    func didView(media: InteractableMedia<EncryptedMedia>) {
    }
}
