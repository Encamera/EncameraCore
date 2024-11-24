//
//  ImageViewingUIView.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.24.
//

import Foundation
import UIKit
import Combine
import EncameraCore

class ImageViewingUIView: UIView, MediaViewProtocol {

    

    typealias ViewModel = ImageViewingViewModel
    typealias HostingView = UIImageView
    // View model
    internal let viewModel: ImageViewingViewModel?
    private var cancellables = Set<AnyCancellable>()

    // UI Components
    internal let hostingView = UIImageView()
    var activityIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .large)
    var errorLabel: UILabel = UILabel()

    required init(viewModel: ImageViewingViewModel) {
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
                if let imageData = decryptedFileRef?.imageData, let image = UIImage(data: imageData) {
                    self.hostingView.image = image
                    self.hostingView.isHidden = false
                    self.activityIndicator.stopAnimating()
                    self.errorLabel.isHidden = true
                }
            }
            .store(in: &cancellables)

        // Observe errors
        viewModel?.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.errorLabel.text = "Error: \(error.localizedDescription)"
                    self.errorLabel.isHidden = false
                    self.activityIndicator.stopAnimating()
                    self.hostingView.isHidden = true
                }
            }
            .store(in: &cancellables)
    }
}
