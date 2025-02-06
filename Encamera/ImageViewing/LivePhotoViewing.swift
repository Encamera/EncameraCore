//
//  ImageViewing.swift
//  encamera
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Combine
import EncameraCore
import AVFoundation
import Photos


class LivePhotoViewingViewModel: ObservableObject, MediaViewModelProtocol {

    @Published var decryptedFileRef: InteractableMedia<CleartextMedia>?
    @Published var preparedLivePhoto: PHLivePhoto?
    @Published var loadingProgress: Double = 0.0
    var pageIndex: Int
    var sourceMedia: InteractableMedia<EncryptedMedia>
    var fileAccess: FileAccess
    @Published var error: MediaViewingError?

    private var livePhotoFinished: (() -> Void)?
    internal var delegate: MediaViewingDelegate
    private var cancellables = Set<AnyCancellable>()  // Store cancellables

    required init(sourceMedia: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, delegate: MediaViewingDelegate, pageIndex: Int) {
        self.pageIndex = pageIndex
        self.sourceMedia = sourceMedia
        self.fileAccess = fileAccess
        self.delegate = delegate
    }

    func reset() {
        decryptedFileRef = nil
        cancellables.forEach({ $0.cancel() })
        cancellables.removeAll()
    }

    func decryptAndSet() async {
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

            // Subscribe to the Combine publisher for generating the live photo
            result.generateLivePhoto()
                .receive(on: RunLoop.main)
                .sink(receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        self.error = .decryptError(wrapped: error)
                    }
                }, receiveValue: { livePhoto in
                    debugPrint("Decrypt and set live photo \(livePhoto)")
                    self.preparedLivePhoto = livePhoto
                    self.decryptedFileRef = result
                    self.delegate.didView(media: self.sourceMedia)
                    if let uiImage = result.uiImage {
                        self.delegate.didLoad(media: uiImage, atIndex: self.pageIndex)
                    }
                })
                .store(in: &cancellables)

        } catch {
            self.error = .decryptError(wrapped: error)
        }
    }
}
