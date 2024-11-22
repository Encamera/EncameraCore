//
//  LivePhotoUIView.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.24.
//

import Foundation
import UIKit
import Combine
import PhotosUI
import EncameraCore

class LivePhotoViewingUIView: UIView, MediaViewProtocol {



    typealias ViewModel = LivePhotoViewingViewModel

    // View model
    internal let viewModel: LivePhotoViewingViewModel?
    private var cancellables = Set<AnyCancellable>()

    // UI Components
    private let livePhotoView = PHLivePhotoView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let errorLabel = UILabel()

    required init(viewModel: ViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)

        setupViews()
        setupBindings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        // Setup live photo view
        livePhotoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(livePhotoView)

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
            livePhotoView.topAnchor.constraint(equalTo: topAnchor),
            livePhotoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            livePhotoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            livePhotoView.bottomAnchor.constraint(equalTo: bottomAnchor),

            progressView.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressView.centerYAnchor.constraint(equalTo: centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)
        ])

        // Initially hide all components except the progress view
        livePhotoView.isHidden = true
        errorLabel.isHidden = true
    }

    private func setupBindings() {
        // Observe changes in preparedLivePhoto
        viewModel?.$preparedLivePhoto
            .receive(on: RunLoop.main)
            .sink { [weak self] livePhoto in
                guard let self = self else { return }
                if let livePhoto = livePhoto {
                    self.livePhotoView.livePhoto = livePhoto
                    self.livePhotoView.isHidden = false
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

//         Observe errors
        viewModel?.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.errorLabel.text = "Error: \(error.localizedDescription)"
                    self.errorLabel.isHidden = false
                    self.progressView.isHidden = true
                    self.livePhotoView.isHidden = true
                }
            }
            .store(in: &cancellables)
    }
}
