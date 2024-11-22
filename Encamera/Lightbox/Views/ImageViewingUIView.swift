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

    // View model
    internal let viewModel: ImageViewingViewModel?
    private var cancellables = Set<AnyCancellable>()

    // UI Components
    private let imageView = UIImageView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let errorLabel = UILabel()

    required init(viewModel: ImageViewingViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)

        setupViews()
        setupBindings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        // Setup image view
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        // Setup progress view
        progressView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressView)

        // Setup error label
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        addSubview(errorLabel)

        // Layout Constraints
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            progressView.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressView.centerYAnchor.constraint(equalTo: centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)
        ])

        // Initially hide all components except the progress view
        imageView.isHidden = true
        errorLabel.isHidden = true
    }

    private func setupBindings() {
        // Observe changes in decryptedFileRef
        viewModel?.$decryptedFileRef
            .receive(on: RunLoop.main)
            .sink { [weak self] decryptedFileRef in
                guard let self = self else { return }
                if let imageData = decryptedFileRef?.imageData, let image = UIImage(data: imageData) {
                    self.imageView.image = image
                    self.imageView.isHidden = false
                    self.progressView.isHidden = true
                    self.errorLabel.isHidden = true
                }
            }
            .store(in: &cancellables)

        // Observe changes in loadingProgress
        viewModel?.$loadingProgress
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                guard let self = self else { return }
                self.progressView.progress = Float(progress)
                if progress >= 1.0 {
                    self.progressView.isHidden = true
                } else {
                    self.progressView.isHidden = false
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
                    self.progressView.isHidden = true
                    self.imageView.isHidden = true
                }
            }
            .store(in: &cancellables)
    }
}
