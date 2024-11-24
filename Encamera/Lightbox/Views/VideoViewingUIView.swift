

import Foundation
import UIKit
import Combine
import EncameraCore

//
//  ImageViewing.swift
//  encamera
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Combine
import EncameraCore


class VideoViewingViewModel: ObservableObject, MediaViewModelProtocol {


    typealias MagnificationGestureType = _EndedGesture<_ChangedGesture<MagnifyGesture>>
    typealias DragGestureType = _EndedGesture<_ChangedGesture<DragGesture>>
    typealias TapGestureType = _EndedGesture<TapGesture>

    @Published var decryptedFileRef: InteractableMedia<CleartextMedia>?
    @Published var loadingProgress: Double = 0.0
    @Published var currentScale: CGFloat = 1.0
    @Published var finalScale: CGFloat = 1.0
    @Published var finalOffset: CGSize = .zero
    @Published var currentOffset: CGSize = .zero
    @Published var currentFrame: CGRect = .zero

    var sourceMedia: InteractableMedia<EncryptedMedia>
    var fileAccess: FileAccess
    @Published var error: MediaViewingError?
    var pageIndex: Int
    private var delegate: MediaViewingDelegate

    required init(sourceMedia: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, delegate: MediaViewingDelegate, pageIndex: Int) {
        self.pageIndex = pageIndex
        self.sourceMedia = sourceMedia
        self.fileAccess = fileAccess
        self.delegate = delegate
    }

    func decryptAndSet() {
        Task { [self] in
            do {
                let result = try await fileAccess.loadMediaPreview(for: sourceMedia)
                await MainActor.run {
                    decryptedFileRef = try? InteractableMedia(underlyingMedia: [result.thumbnailMedia])
                    delegate.didView(media: sourceMedia)
                    if let uiImage = sourceMedia.uiImage {
                        delegate.didLoad(media: uiImage, atIndex: pageIndex)
                    }
                }
                
            } catch {
                self.error = .decryptError(wrapped: error)
            }
        }
    }
}

class VideoViewingUIView: UIView, MediaViewProtocol {



    typealias ViewModel = VideoViewingViewModel
    typealias HostingView = UIImageView
    // View model
    internal let viewModel: VideoViewingViewModel?
    private var cancellables = Set<AnyCancellable>()

    // UI Components
    internal let hostingView = UIImageView()
    var activityIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .large)
    var errorLabel: UILabel = UILabel()

    required init(viewModel: VideoViewingViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        setupViews()
        setupBindings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupBindings() {
        // Observe changes in decryptedFileRef
        viewModel?.$decryptedFileRef
            .receive(on: RunLoop.main)
            .sink { [weak self] decryptedFileRef in
                guard let self = self else { return }
//                if case .data(let imageData) = decryptedFileRef?., let image = UIImage(data: imageData) {
//                    self.hostingView.image = image
//                    self.hostingView.isHidden = false
//                    self.activityIndicator.stopAnimating()
//                    self.errorLabel.isHidden = true
//                }
            }
            .store(in: &cancellables)

        // Observe errors
        viewModel?.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.errorLabel.text = "Error: \(error.displayDescription)"
                    self.errorLabel.isHidden = false
                    self.activityIndicator.stopAnimating()
                    self.hostingView.isHidden = true
                }
            }
            .store(in: &cancellables)
    }
}
