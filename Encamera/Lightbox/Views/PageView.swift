import UIKit
import PhotosUI
import EncameraCore

protocol PageViewDelegate: AnyObject {
    @MainActor
    func pageViewDidZoom(_ pageView: PageView)
    @MainActor
    func imageDidLoad(_ image: UIImage?, atIndex: Int)
    @MainActor
    func pageView(_ pageView: PageView, didTouchPlayButton videoURL: URL)
    @MainActor
    func pageViewDidTouch(_ pageView: PageView)
    @MainActor
    func pageViewDidTap(_ pageView: PageView)
    @MainActor
    func pageViewDidDoubleTap(_ pageView: PageView)}

class PageView: UIScrollView {

    lazy var imageView: any MediaViewProtocol = {
        guard let image = self.image else {
            return EmptyMediaView()
        }
        switch image.mediaType {
        case .livePhoto:

            let viewModel = LivePhotoViewingUIView.ViewModel(sourceMedia: image, fileAccess: self.fileAccess, delegate: self, pageIndex: pageIndex)
            return LivePhotoViewingUIView(viewModel: viewModel)
        case .stillPhoto:
            let viewModel = ImageViewingUIView.ViewModel(sourceMedia: image, fileAccess: self.fileAccess, delegate: self, pageIndex: pageIndex)
            return ImageViewingUIView(viewModel: viewModel)
        case .video:
            let viewModel = VideoViewingUIView.ViewModel(sourceMedia: image, fileAccess: self.fileAccess, delegate: self, pageIndex: pageIndex)
            return VideoViewingUIView(viewModel: viewModel)
        }
    }()



    lazy var playButton: UIButton = {
        let button = UIButton(type: .custom)
        button.frame.size = CGSize(width: 60, height: 60)
        var buttonImage = AssetManager.image("lightbox_play")

        // Note by Elvis Nuñez on Mon 22 Jun 08:06
        // When using SPM you might find that assets are note included. This is a workaround to provide default assets
        // under iOS 13 so using SPM can work without problems.
        if #available(iOS 13.0, *) {
            if buttonImage == nil {
                buttonImage = UIImage(systemName: "play.circle.fill")
            }
        }

        button.setBackgroundImage(buttonImage, for: UIControl.State())
        button.addTarget(self, action: #selector(playButtonTouched(_:)), for: .touchUpInside)
        button.tintColor = .white

        button.layer.shadowOffset = CGSize(width: 1, height: 1)
        button.layer.shadowColor = UIColor.gray.cgColor
        button.layer.masksToBounds = false
        button.layer.shadowOpacity = 0.8

        return button
    }()

    lazy var loadingIndicator: UIView = LightboxConfig.makeLoadingIndicator()

    var image: LightboxImage?
    weak var pageViewDelegate: (any PageViewDelegate)?

    var hasZoomed: Bool {
        return zoomScale != 1.0
    }

    private var fileAccess: FileAccess
    private var pageIndex: Int
    private var showPurchaseOverlay: Bool
    let photoLimitReachedView: PhotoLimitReachedView

    // MARK: - Initializers

    init(image: LightboxImage?, fileAccess: FileAccess, pageIndex: Int, showPurchaseOverlay: Bool, upgradeButtonPressed: @escaping () -> Void) {
        self.photoLimitReachedView = PhotoLimitReachedView(frame: .zero, upgradeAction: {
            upgradeButtonPressed()
        })

        self.showPurchaseOverlay = showPurchaseOverlay
        self.image = image
        self.fileAccess = fileAccess
        self.pageIndex = pageIndex
        super.init(frame: CGRect.zero)
        configure()

    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    func configure() {
        if showPurchaseOverlay {
            addSubview(photoLimitReachedView)
            photoLimitReachedView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                photoLimitReachedView.centerXAnchor.constraint(equalTo: centerXAnchor),
                photoLimitReachedView.centerYAnchor.constraint(equalTo: centerYAnchor),
                photoLimitReachedView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.75), // 75% of the screen width
                photoLimitReachedView.heightAnchor.constraint(equalToConstant: 500) // Fixed height of 500
            ])


        } else {
            addSubview(imageView)

            updatePlayButton()

            addSubview(loadingIndicator)

            delegate = self
            isMultipleTouchEnabled = true
            minimumZoomScale = LightboxConfig.Zoom.minimumScale
            maximumZoomScale = LightboxConfig.Zoom.maximumScale
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false

            let doubleTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(scrollViewDoubleTapped(_:)))
            doubleTapRecognizer.numberOfTapsRequired = 2
            doubleTapRecognizer.numberOfTouchesRequired = 1
            addGestureRecognizer(doubleTapRecognizer)

            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(viewTapped(_:)))
            addGestureRecognizer(tapRecognizer)

            tapRecognizer.require(toFail: doubleTapRecognizer)
        }
    }

    private var loadingTask: Task<Void, Never>?
    func cancelLoading() {
        imageView.viewModel?.reset()
        loadingTask?.cancel()
        loadingTask = nil
        imageView.reset()
    }
    // MARK: - Update
    func update(with image: LightboxImage?) {
        self.image = image
        updatePlayButton()
        if let image,
            imageView.image == nil,
            loadingTask == nil {
            loadingTask = Task {
                await imageView.setMediaAndLoad(image: image)
            }
        }
    }

    func updatePlayButton() {
        guard let image = image else { return }
        if image.mediaType == .video && !subviews.contains(playButton) && imageView.image != nil {
            addSubview(playButton)
        } else if subviews.contains(playButton) {
            playButton.removeFromSuperview()
        }
    }

    // MARK: - Recognizers

    @objc func scrollViewDoubleTapped(_ recognizer: UITapGestureRecognizer) {

        let pointInView = recognizer.location(in: imageView)
        let newZoomScale = zoomScale > minimumZoomScale
        ? minimumZoomScale
        : maximumZoomScale

        let width = frame.size.width / newZoomScale
        let height = frame.size.height / newZoomScale
        let x = pointInView.x - (width / 2.0)
        let y = pointInView.y - (height / 2.0)

        let rectToZoomTo = CGRect(x: x, y: y, width: width, height: height)

        zoom(to: rectToZoomTo, animated: true)
        pageViewDelegate?.pageViewDidDoubleTap(self)
    }

    @objc func viewTapped(_ recognizer: UITapGestureRecognizer) {
        pageViewDelegate?.pageViewDidTouch(self)
        pageViewDelegate?.pageViewDidTap(self)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        loadingIndicator.center = imageView.center
        playButton.center = imageView.center
    }

    func configureImageView() {
        guard let imageView = imageView as? UIImageView else {
            centerImageView()
            return
        }

        let imageViewSize = imageView.frame.size
        let imageSize = image?.uiImage?.size ?? .zero
        let realImageViewSize: CGSize

        if imageSize.width / imageSize.height > imageViewSize.width / imageViewSize.height {
            realImageViewSize = CGSize(
                width: imageViewSize.width,
                height: imageViewSize.width / imageSize.width * imageSize.height)
        } else {
            realImageViewSize = CGSize(
                width: imageViewSize.height / imageSize.height * imageSize.width,
                height: imageViewSize.height)
        }

        imageView.frame = CGRect(origin: CGPoint.zero, size: realImageViewSize)

        centerImageView()
    }

    func centerImageView() {
        let boundsSize = frame.size
        var imageViewFrame = imageView.frame

        if imageViewFrame.size.width < boundsSize.width {
            imageViewFrame.origin.x = (boundsSize.width - imageViewFrame.size.width) / 2.0
        } else {
            imageViewFrame.origin.x = 0.0
        }

        if imageViewFrame.size.height < boundsSize.height {
            imageViewFrame.origin.y = (boundsSize.height - imageViewFrame.size.height) / 2.0
        } else {
            imageViewFrame.origin.y = 0.0
        }
        imageView.frame = imageViewFrame
    }

    // MARK: - Action


    @objc func playButtonTouched(_ button: UIButton) {
        guard let image else {
            return
        }

        let alertController = UIAlertController(title: L10n.Alert.LoadingFile.title, message: L10n.Alert.LoadingFile.message, preferredStyle: .alert)

        // Add a progress view to the alert
        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        alertController.view.addSubview(progressView)

        NSLayoutConstraint.activate([
            progressView.leadingAnchor.constraint(equalTo: alertController.view.leadingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: alertController.view.trailingAnchor, constant: -20),
            progressView.bottomAnchor.constraint(equalTo: alertController.view.bottomAnchor, constant: -50),
        ])

        let task = createLoadMediaTask(for: image, alertController: alertController, progressView: progressView)


        alertController.addAction(UIAlertAction(title: L10n.cancel, style: .cancel) { _ in 
            task.cancel()
        })

        // Present the alert controller
        if let topController = UIApplication.topMostViewController() {
            topController.present(alertController, animated: true, completion: nil)
        }


    }

    private func createLoadMediaTask(for media: InteractableMedia<EncryptedMedia>, alertController: UIAlertController, progressView: UIProgressView) -> Task<Void, Never> {
        return Task {
            do {
                let decryptedVideo = try await fileAccess.loadMediaToURLs(media: media) { status in
                    DispatchQueue.main.async {
                        switch status {
                        case .notLoaded:
                            progressView.progress = 0.0
                            alertController.message = L10n.ProgressView.startingDownload
                        case .downloading(let progress):
                            progressView.progress = Float(progress)
                            alertController.message = L10n.ProgressView.downloading(Float(progress) * 100)
                        case .decrypting(let progress):
                            progressView.progress = Float(progress)
                            alertController.message = L10n.ProgressView.decrypting(Float(progress) * 100)
                        case .loaded:
                            progressView.progress = 1.0
                            alertController.message = L10n.ProgressView.fileLoadedSuccessfully
                        }
                    }
                }
                guard let decryptedVideo = decryptedVideo.first else { return }

                await MainActor.run {
                    alertController.dismiss(animated: true, completion: { [weak self] in
                        guard let self else {
                            return
                        }
                        self.pageViewDelegate?.pageView(self, didTouchPlayButton: decryptedVideo as URL)
                    })
                }
            } catch  {
                
                guard let chunkedError = error as? ChunkedFilesError, chunkedError != .operationCancelled else {
                    return
                }
                await MainActor.run {
                    alertController.dismiss(animated: true, completion: nil)
                    var errorString: String
                    if let viewingError = error as? ErrorDescribable {
                        errorString = viewingError.displayDescription
                    } else {
                        errorString = error.localizedDescription
                    }
                    // Handle error if needed, e.g., show an error alert
                    let errorAlert = UIAlertController(title: L10n.Error.Alert.title, message: L10n.Error.Alert.failedToLoadFile(errorString), preferredStyle: .alert)
                    errorAlert.addAction(UIAlertAction(title: L10n.ok, style: .default, handler: nil))
                    if let topController = UIApplication.topMostViewController() {
                        topController.present(errorAlert, animated: true, completion: nil)
                    }
                }
            }
        }
    }

}

extension PageView: MediaViewingDelegate {
    func didView(media: InteractableMedia<EncryptedMedia>) {

    }

    func didLoad(media: UIImage, atIndex index: Int) {
        pageViewDelegate?.imageDidLoad(media, atIndex: index)
        updatePlayButton()
    }
}

// MARK: - LayoutConfigurable

extension PageView: LayoutConfigurable {

    @objc func configureLayout() {

        contentSize = frame.size
        imageView.frame = frame
        zoomScale = minimumZoomScale

        configureImageView()
    }
}

// MARK: - UIScrollViewDelegate

extension PageView: UIScrollViewDelegate {

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
        pageViewDelegate?.pageViewDidZoom(self)
    }
}
