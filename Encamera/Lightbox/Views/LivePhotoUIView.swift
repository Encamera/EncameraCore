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
    private let activityIndicator = UIActivityIndicatorView(style: .large)
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

        // Setup activity indicator
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        addSubview(activityIndicator)

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

            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)
        ])

        // Initially hide all components except the activity indicator
        livePhotoView.isHidden = true
        errorLabel.isHidden = true
        activityIndicator.startAnimating()
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
                    self.livePhotoView.isHidden = true
                }
            }
            .store(in: &cancellables)
    }
}
