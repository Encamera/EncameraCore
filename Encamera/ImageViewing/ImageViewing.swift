//
//  ImageViewing.swift
//  encamera
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Combine
import EncameraCore


class ImageViewingViewModel: ObservableObject, MediaViewModelProtocol {

    @Published var decryptedFileRef: InteractableMedia<CleartextMedia>?
    @Published var loadingProgress: Double = 0.0
    @Published var currentScale: CGFloat = 1.0
    @Published var finalScale: CGFloat = 1.0
    @Published var finalOffset: CGSize = .zero
    @Published var currentOffset: CGSize = .zero
    @Published var currentFrame: CGRect = .zero
    var pageIndex: Int

    var sourceMedia: InteractableMedia<EncryptedMedia>
    var fileAccess: FileAccess
    @Published var error: MediaViewingError?

    private var delegate: MediaViewingDelegate

    required init(sourceMedia: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, delegate: MediaViewingDelegate, pageIndex: Int) {
        self.sourceMedia = sourceMedia
        self.fileAccess = fileAccess
        self.delegate = delegate
        self.pageIndex = pageIndex
    }

    func decryptAndSet() {
        Task { [self] in
            do {
                let result = try await fileAccess.loadMedia(media: sourceMedia) { [self] progress in
                    switch progress {
                    case .decrypting(progress: let progress), .downloading(progress: let progress):
                        loadingProgress = progress
                    case .loaded:
                        loadingProgress = 1.0
                    case .notLoaded:
                        loadingProgress = 0.0
                    }
                }
                await MainActor.run {
                    decryptedFileRef = result
                    if let uiImage = result.uiImage {
                        delegate.didLoad(media: uiImage, atIndex: pageIndex)
                        delegate.didView(media: sourceMedia)
                    }
                }

            } catch {
                self.error = .decryptError(wrapped: error)
            }
        }
    }
}
