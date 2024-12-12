import Foundation
import UIKit
import Combine
import PhotosUI
import EncameraCore

class LivePhotoViewingUIView: UIView, MediaViewProtocol {

    typealias ViewModel = LivePhotoViewingViewModel
    typealias HostingView = PHLivePhotoView
    // View model
    internal var viewModel: LivePhotoViewingViewModel?
    private var cancellables = Set<AnyCancellable>()

    // UI Components
    internal let hostingView = PHLivePhotoView()
    var activityIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .large)
    var errorLabel: UILabel = UILabel()

    required init(viewModel: ViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)

        setupViews()
        setupBindings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reset() {
        hostingView.livePhoto = nil
    }

    private func setupBindings() {
        // Observe changes in preparedLivePhoto
        viewModel?.$preparedLivePhoto
            .receive(on: RunLoop.main)
            .sink { [weak self] livePhoto in
                guard let self = self else { return }
                if let livePhoto = livePhoto {
                    self.hostingView.livePhoto = livePhoto
                    self.hostingView.isHidden = false
                    self.activityIndicator.stopAnimating()
                    self.errorLabel.isHidden = true
                    self.hostingView.startPlayback(with: .hint)
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
