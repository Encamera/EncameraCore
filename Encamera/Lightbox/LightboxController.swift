import UIKit
import EncameraCore

public typealias LightboxImage = InteractableMedia<EncryptedMedia>

public protocol LightboxControllerPageDelegate: AnyObject {
    @MainActor
    func lightboxController(_ controller: LightboxController, didMoveToPage page: Int)
}

public protocol LightboxControllerDismissalDelegate: AnyObject {
    @MainActor
    func lightboxControllerWillDismiss(_ controller: LightboxController)
}

public protocol LightboxControllerTouchDelegate: AnyObject {
    @MainActor
    func lightboxController(_ controller: LightboxController, didTouch image: LightboxImage, at index: Int)
}

public protocol LightboxControllerTapDelegate: AnyObject {
    @MainActor
    func lightboxController(_ controller: LightboxController, didTap image: LightboxImage, at index: Int)
    @MainActor
    func lightboxController(_ controller: LightboxController, didDoubleTap image: LightboxImage, at index: Int)
}

public protocol LightboxControllerDeleteDelegate: AnyObject {
    @MainActor
    func lightboxController(_ controller: LightboxController, willDeleteAt index: Int)
}

open class LightboxController: UIViewController {

    // MARK: - Internal views

    lazy var scrollView: UIScrollView = { [unowned self] in
        let scrollView = UIScrollView()
        scrollView.isPagingEnabled = false
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = UIScrollView.DecelerationRate.fast

        return scrollView
    }()

    lazy var effectView: UIVisualEffectView = {
        let effect = UIBlurEffect(style: .dark)
        let view = UIVisualEffectView(effect: effect)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        return view
    }()

    lazy var backgroundView: UIImageView = {
        let view = UIImageView()
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        return view
    }()

    // MARK: - Public views

    open fileprivate(set) lazy var footerView: FooterView = { [unowned self] in
        let view = FooterView()
        view.delegate = self

        return view
    }()

    // MARK: - Properties
    open fileprivate(set) var currentPage = 0 {
        didSet {
            currentPage = min(numberOfPages - 1, max(0, currentPage))


            pageDelegate?.lightboxController(self, didMoveToPage: currentPage)

            reconfigurePagesForPreload()

            cancelNonPreloadPages()

            let page = pageViews[currentPage]
            configure(for: page)
        }
    }

    func configure(for page: PageView) {
        if let media = page.image, let image = page.imageView.image {
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.125) {
                self.loadDynamicBackground(image)
                self.footerView.media = media
            }
        }
        
    }

    func reconfigurePagesForPreload() {
        let preloadIndicies = calculatePreloadIndicies()

        for i in 0..<initialImages.count {
            let pageView = pageViews[i]
            if preloadIndicies.contains(i) {
                if pageView.image == nil {
                    pageView.update(with: initialImages[i])
                }
            } else {
                pageView.update(with: nil)
            }
        }
    }

    func cancelNonPreloadPages() {
        let preloadIndicies = calculatePreloadIndicies()

        for i in 0..<pageViews.count {
            if !preloadIndicies.contains(i) {
                pageViews[i].cancelLoading()
            }
        }
    }

    open var numberOfPages: Int {
        return pageViews.count
    }

    open var dynamicBackground: Bool = true {
        didSet {
            configureDynamicBackground()
        }
    }

    open var spacing: CGFloat = 20 {
        didSet {
            configureLayout(view.bounds.size)
        }
    }


    open var images: [LightboxImage] {
        get {
            return initialImages
        }
        set(value) {
            initialImages = value
            configurePages(value)
        }
    }

    open weak var pageDelegate: (any LightboxControllerPageDelegate)?
    open weak var dismissalDelegate: (any LightboxControllerDismissalDelegate)?
    open weak var imageTouchDelegate: (any LightboxControllerTouchDelegate)?
    open weak var imageTapDelegate: (any LightboxControllerTapDelegate)?
    open weak var imageDeleteDelegate: (any LightboxControllerDeleteDelegate)?
    open internal(set) var presented = false
    let closeButton = UIButton(type: .system)
    lazy var transitionManager: LightboxTransition = LightboxTransition()
    var pageViews = [PageView]()

    fileprivate var initialImages: [InteractableMedia<EncryptedMedia>]
    fileprivate let initialPage: Int
    private let fileAccess: FileAccess
    private let purchasePermissionsManager: PurchasedPermissionManaging
    private let purchaseButtonPressed: () -> (Void)
    private let reviewAlertActionPressed: (AskForReviewUtil.ReviewSelection) -> (Void)
    private var footerViewHeightConstraint: NSLayoutConstraint!
    private var isFooterExpanded = false
    private var statusBarHidden = false

    open override var prefersStatusBarHidden: Bool {
        return statusBarHidden
    }

    // MARK: - Initializers

    public init(images: [LightboxImage] = [], startIndex index: Int = 0, fileAccess: FileAccess, purchasePermissionsManager: PurchasedPermissionManaging, purchaseButtonPressed: @escaping () -> (Void), reviewAlertActionPressed: @escaping (AskForReviewUtil.ReviewSelection) -> (Void)) {
        self.purchaseButtonPressed = purchaseButtonPressed
        self.fileAccess = fileAccess
        self.initialImages = images
        self.initialPage = index
        self.currentPage = index
        self.purchasePermissionsManager = purchasePermissionsManager
        self.reviewAlertActionPressed = reviewAlertActionPressed
        super.init(nibName: nil, bundle: nil)
        self.pageDelegate = self
    }

    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View lifecycle

    open override func viewDidLoad() {
        super.viewDidLoad()
        edgesForExtendedLayout = [.top, .bottom]
        modalPresentationStyle = .fullScreen

        view.backgroundColor = LightboxConfig.imageBackgroundColor
        transitionManager.lightboxController = self
        transitionManager.scrollView = scrollView
        transitioningDelegate = transitionManager

        [scrollView, footerView].forEach {
            view.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        footerViewHeightConstraint = footerView.heightAnchor.constraint(equalToConstant: 76)

        NSLayoutConstraint.activate([
            // Constraints for footerView
            footerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerViewHeightConstraint,

            // Constraints for scrollView
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        configurePages(initialImages)
        configure(for: pageViews[currentPage])
        goTo(initialPage, animated: false)
        configureDynamicBackground()

        addCloseButton()
    }

    private func addCloseButton() {

        closeButton.setImage(UIImage(named: "Album-BackButton"), for: .normal)
        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)

        view.addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 60),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 0),
            closeButton.trailingAnchor.constraint(equalTo: view.leadingAnchor, constant: 60)
        ])
    }

    @objc private func closeButtonTapped() {
        dismiss(completion: {})
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        AskForReviewUtil.askForReviewIfNeeded(completion: self.reviewAlertActionPressed)
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if !presented {
            presented = true
            configureLayout(view.frame.size)
        }
    }

    // MARK: - Supported Orientations

    open override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return [.portrait, .landscapeLeft, .landscapeRight]
    }

    open override var shouldAutorotate: Bool {
        return true
    }

    // MARK: - Rotation

    override open func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.configureLayout(size)
        }, completion: nil)
    }

    // MARK: - Configuration

    func configureDynamicBackground() {
        if dynamicBackground == true {
            effectView.frame = view.frame
            backgroundView.frame = effectView.frame
            view.insertSubview(effectView, at: 0)
            view.insertSubview(backgroundView, at: 0)
        } else {
            effectView.removeFromSuperview()
            backgroundView.removeFromSuperview()
        }
    }

    func configurePages(_ images: [LightboxImage]) {
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews = []

        for pageIndex in 0..<images.count {
            let showPurchaseOverlay = !purchasePermissionsManager.isAllowedAccess(feature: .accessPhoto(count: Double(images.count - pageIndex)))
            let pageView = PageView(image: images[pageIndex], fileAccess: fileAccess, pageIndex: pageIndex, showPurchaseOverlay: showPurchaseOverlay, upgradeButtonPressed: { [weak self] in
                self?.dismiss(completion: {
                    self?.purchaseButtonPressed()
                })
            })
            pageView.pageViewDelegate = self

            scrollView.addSubview(pageView)
            pageViews.append(pageView)
        }

        let indicesToLoad = calculatePreloadIndicies()

        indicesToLoad.forEach({ index in
            let page = pageViews[index]
            let image = images[index]
            page.update(with: image)
        })

        configureLayout(view.bounds.size)
    }

    // MARK: - Pagination

    open func goTo(_ page: Int, animated: Bool = true) {
        guard page >= 0 && page < numberOfPages else {
            return
        }

        currentPage = page

        var offset = scrollView.contentOffset
        offset.x = CGFloat(page) * (scrollView.frame.width + spacing)

        let shouldAnimated = view.window != nil ? animated : false

        scrollView.setContentOffset(offset, animated: shouldAnimated)
    }

    open func next(_ animated: Bool = true) {
        goTo(currentPage + 1, animated: animated)
    }

    open func previous(_ animated: Bool = true) {
        goTo(currentPage - 1, animated: animated)
    }


    // MARK: - Layout

    open func configureLayout(_ size: CGSize) {
        scrollView.contentSize = CGSize(
            width: size.width * CGFloat(numberOfPages) + spacing * CGFloat(numberOfPages - 1),
            height: size.height)
        scrollView.contentOffset = CGPoint(x: CGFloat(currentPage) * (size.width + spacing), y: 0)

        for (index, pageView) in pageViews.enumerated() {
            let point = CGPoint(x:(size.width + spacing) * CGFloat(index), y: 0)
            pageView.frame = CGRect(origin: point, size: size)
            pageView.configureLayout()
            if index != numberOfPages - 1 {
                pageView.frame.size.width += spacing
            }
        }
    }


    fileprivate func loadDynamicBackground(_ image: UIImage) {
        backgroundView.image = image
        backgroundView.layer.add(CATransition(), forKey: "fade")
    }


    func toggleControls(pageView: PageView?, visible: Bool, duration: TimeInterval = 0.1, delay: TimeInterval = 0) {
        let alpha: CGFloat = visible ? 1.0 : 0.0
        closeButton.alpha = visible ? 1.0 : 0.0
        pageView?.playButton.isHidden = !visible

        // Update statusBarHidden variable and request the status bar update
        statusBarHidden = !visible
        setNeedsStatusBarAppearanceUpdate()

        UIView.animate(withDuration: duration, delay: delay, options: [], animations: {
            self.footerView.alpha = alpha
            pageView?.playButton.alpha = alpha
        }, completion: nil)
    }
    // MARK: - Helper functions
    func calculatePreloadIndicies () -> [Int] {
        var preloadIndicies: [Int] = []
        let preload = LightboxConfig.preload
        if preload > 0 {
            let lb = max(0, currentPage - preload)
            let rb = min(initialImages.count, currentPage + preload)
            for i in lb..<rb {
                preloadIndicies.append(i)
            }
        } else {
            preloadIndicies = [Int](0..<initialImages.count)
        }
        return preloadIndicies
    }

    func dismiss(completion: @escaping () -> Void = {}) {
        presented = false
        dismissalDelegate?.lightboxControllerWillDismiss(self)
        dismiss(animated: true, completion: completion)
    }

    // New Alert View Function
    func presentDeleteAlert(deleteButton: UIButton) {
        let alert = UIAlertController(
            title: L10n.AlbumDetailView.confirmDeletion,
            message: L10n.AlbumDetailView.deleteSelectedMedia(L10n.imageS(1)),
            preferredStyle: .alert
        )

        let deleteAction = UIAlertAction(title: L10n.delete, style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.performDelete(deleteButton: deleteButton)
        }
        let cancelAction = UIAlertAction(title: L10n.cancel, style: .cancel, handler: nil)

        alert.addAction(deleteAction)
        alert.addAction(cancelAction)

        present(alert, animated: true, completion: nil)
    }

    // Separate delete functionality
    private func performDelete(deleteButton: UIButton) {
        deleteButton.isEnabled = false
        let targetMedia = initialImages[currentPage]
        Task {
            do {
                try await fileAccess.delete(media: targetMedia)
                Task { @MainActor in
                    guard numberOfPages != 1 else {
                        pageViews.removeAll()
                        dismiss()
                        return
                    }

                    let prevIndex = currentPage

                    if currentPage == numberOfPages - 1 {
                        previous()
                    } else {
                        next()
                        currentPage -= 1
                    }

                    self.initialImages.remove(at: prevIndex)
                    self.pageViews.remove(at: prevIndex).removeFromSuperview()

                    DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.5) {
                        self.configureLayout(self.view.bounds.size)
                        self.currentPage = Int(self.scrollView.contentOffset.x / self.view.bounds.width)
                        deleteButton.isEnabled = true
                    }
                }

            } catch {
                // handle error
            }
        }


    }
}

// MARK: - UIScrollViewDelegate

extension LightboxController: UIScrollViewDelegate {

    public func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        var speed: CGFloat = velocity.x < 0 ? -2 : 2

        if velocity.x == 0 {
            speed = 0
        }

        let pageWidth = scrollView.frame.width + spacing

        var x = scrollView.contentOffset.x + speed * 60.0

        if speed > 0 {
            x = ceil(x / pageWidth) * pageWidth
        } else if speed < -0 {
            x = floor(x / pageWidth) * pageWidth
        } else {
            x = round(x / pageWidth) * pageWidth
        }

        targetContentOffset.pointee.x = x
        currentPage = Int(x / pageWidth)
    }
}

// MARK: - PageViewDelegate

extension LightboxController: PageViewDelegate {

    func imageDidLoad(_ image: UIImage?, atIndex index: Int) {
        let loadedPage = pageViews[currentPage]
        configure(for: loadedPage)
    }

    func pageViewDidZoom(_ pageView: PageView) {
        let duration = pageView.hasZoomed ? 0.1 : 0.5
        toggleControls(pageView: pageView, visible: !pageView.hasZoomed, duration: duration, delay: 0.5)
    }

    func pageView(_ pageView: PageView, didTouchPlayButton videoURL: URL) {
        guard let viewController = UIApplication.topMostViewController() else {
            return
        }
        EventTracking.trackMovieViewed()

        LightboxConfig.handleVideo(viewController, videoURL)
    }

    func pageViewDidTouch(_ pageView: PageView) {
        guard !pageView.hasZoomed else { return }

        imageTouchDelegate?.lightboxController(self, didTouch: images[currentPage], at: currentPage)

        let visible = (footerView.alpha == 1.0)
        toggleControls(pageView: pageView, visible: !visible)
    }

    func pageViewDidTap(_ pageView: PageView) {
        imageTapDelegate?.lightboxController(self, didTap: images[currentPage], at: currentPage)
    }

    func pageViewDidDoubleTap(_ pageView: PageView) {
        imageTapDelegate?.lightboxController(self, didDoubleTap: images[currentPage], at: currentPage)
    }

    private func toggleFooterView() {
        isFooterExpanded.toggle()
        scrollView.isScrollEnabled = !isFooterExpanded
        footerViewHeightConstraint.constant = isFooterExpanded ? view.frame.height * 0.20 : 76

        UIView.animate(withDuration: 0.3, animations: {
            self.view.layoutIfNeeded()
        })
    }


}

// MARK: - HeaderViewDelegate

extension LightboxController: FooterViewDelegate {

    // MARK: - FooterViewDelegate

    func footerView(_ footerView: FooterView, didPressButton button: UIButton, buttonType: FooterView.ButtonType) {
        switch buttonType {
        case .info, .chevronDown:
            toggleFooterView()
        case .share:
            let currentMedia = initialImages[currentPage]
            let util = ShareMediaUtil(fileAccess: fileAccess, targetMedia: [currentMedia])
            Task {
                do {
                    try await util.prepareSharingData { status in
                        print("Preparing share data")
                    }
                    try await util.showShareSheet()
                } catch {
                    print("Error sharing media: \(error)")
                }
            }
        case .delete:
            presentDeleteAlert(deleteButton: button)
        case .chevronDown:
            // Handle chevron down button press
            break
        }
    }
}

extension LightboxController: LightboxControllerPageDelegate {
    public func lightboxController(_ controller: LightboxController, didMoveToPage page: Int) {
        let loadedPage = images[page]
        if loadedPage.mediaType != .video {
            EventTracking.trackImageViewed()
        }
    }
}
