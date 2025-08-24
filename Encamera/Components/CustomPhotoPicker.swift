import SwiftUI
import Photos
import PhotosUI
import UIKit
import Combine
import AVFoundation

// MARK: - Custom Photo Picker with Swipe Selection
/// A custom photo picker that supports swipe-to-select gesture
/// Requires full photo library access to function
struct CustomPhotoPicker: UIViewControllerRepresentable {
    var selectedItems: ([MediaSelectionResult]) -> ()
    var filter: PHPickerFilter = .images
    var selectionLimit: Int = 0 // 0 for unlimited
    
    func makeUIViewController(context: Context) -> UINavigationController {
        let viewModel = CustomPhotoPickerViewModel()
        viewModel.filter = filter
        viewModel.selectionLimit = selectionLimit
        
        let viewController = CustomPhotoPickerViewController(viewModel: viewModel)
        viewController.onSelection = { assets in
            // Convert PHAssets to MediaSelectionResult
            let results = assets.map { asset in
                MediaSelectionResult.phAsset(asset)
            }
            selectedItems(results)
        }
        
        let navController = UINavigationController(rootViewController: viewController)
        navController.navigationBar.prefersLargeTitles = false
        return navController
    }
    
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        // Update if needed
        if let photoPickerVC = uiViewController.topViewController as? CustomPhotoPickerViewController {
            photoPickerVC.viewModel.updateFilter(filter)
            photoPickerVC.viewModel.updateSelectionLimit(selectionLimit)
        }
    }
}



// MARK: - Custom Photo Picker View Controller
class CustomPhotoPickerViewController: UIViewController {
    
    // MARK: Properties
    var onSelection: (([PHAsset]) -> ())?
    let viewModel: CustomPhotoPickerViewModel
    
    private var collectionView: UICollectionView!
    private let imageManager = PHCachingImageManager()
    
    private var isSwipeSelecting = false
    private var swipeSelectionMode: SwipeSelectionMode = .selecting
    private var processedIndexPaths = Set<IndexPath>()
    private var lastProcessedIndexPath: IndexPath?
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    
    private var cancellables = Set<AnyCancellable>()
    
    // Selection mode indicator view
    private lazy var selectionModeIndicator: UIView = {
        let view = UIView()
        let surface = SurfaceType.darkBackground
        view.backgroundColor = .black
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let label = UILabel()
        label.backgroundColor = .clear
        label.text = NSLocalizedString("CustomPhotoPicker.SwipeInstruction", comment: "")
        label.font = EncameraFont.pt14.uiFont
        label.textColor = surface.textUIColor
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        
        return view
    }()
    
    private enum SwipeSelectionMode {
        case selecting
        case deselecting
    }
    
    // MARK: - Initialization
    init(viewModel: CustomPhotoPickerViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        setupNavigationBar()
        setupCollectionView()
        setupViewModelBindings()
    }
    
    // MARK: - ViewModel Bindings
    private func setupViewModelBindings() {
        // Observe assets changes
        viewModel.$assets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.collectionView.reloadData()
            }
            .store(in: &cancellables)
        
        // Observe selection count changes
        viewModel.$selectionCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNavigationBar()
            }
            .store(in: &cancellables)
        
        // Observe selection mode changes
        viewModel.$isInSelectionMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isInSelectionMode in
                self?.updateSelectionModeUI(isInSelectionMode)
            }
            .store(in: &cancellables)
        
        // Observe authorization status changes
        viewModel.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleAuthorizationStatusChange(status)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Setup
    private func setupNavigationBar() {
        title = NSLocalizedString("CustomPhotoPicker.SelectPhotos", comment: "")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("CustomPhotoPicker.Add", comment: ""),
            style: .done,
            target: self,
            action: #selector(addTapped)
        )
        updateNavigationBar()
    }
    
    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        let spacing: CGFloat = 2
        let columns: CGFloat = 4
        let width = (view.bounds.width - (spacing * (columns - 1))) / columns
        layout.itemSize = CGSize(width: width, height: width)
        layout.minimumInteritemSpacing = spacing
        layout.minimumLineSpacing = spacing
        
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .black
        collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: "PhotoCell")
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.allowsSelection = false // Disable built-in selection completely
        
        // Add tap gesture recognizer for single taps
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))
        tapGesture.delegate = self
        collectionView.addGestureRecognizer(tapGesture)
        
        // Add long press gesture recognizer
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressGesture(_:)))
        longPressGesture.minimumPressDuration = 0.3
        longPressGesture.delegate = self
        collectionView.addGestureRecognizer(longPressGesture)
        
        // Add pan gesture for swipe selection
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        panGesture.delegate = self
        collectionView.addGestureRecognizer(panGesture)
        
        // Add selection mode indicator first
        view.addSubview(selectionModeIndicator)
        view.addSubview(collectionView)
        
        NSLayoutConstraint.activate([
            // Selection mode indicator constraints
            selectionModeIndicator.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            selectionModeIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionModeIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selectionModeIndicator.heightAnchor.constraint(equalToConstant: 36),
            
            // Collection view constraints - positioned below the selection indicator
            collectionView.topAnchor.constraint(equalTo: selectionModeIndicator.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    private func handleAuthorizationStatusChange(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized:
            break // ViewModel handles loading
        case .limited:
            showLimitedAccessBanner()
        case .denied, .restricted:
            showPermissionDeniedAlert()
        case .notDetermined:
            break // ViewModel handles requesting permission
        @unknown default:
            break
        }
    }
    
    private func updateSelectionModeUI(_ isInSelectionMode: Bool) {
        collectionView.isScrollEnabled = !isInSelectionMode
    }
    
    private func showLimitedAccessBanner() {
        let banner = UIView()
        banner.backgroundColor = .systemYellow.withAlphaComponent(0.2)
        banner.translatesAutoresizingMaskIntoConstraints = false
        
        let label = UILabel()
        label.text = NSLocalizedString("CustomPhotoPicker.LimitedAccess", comment: "")
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        
        banner.addSubview(label)
        view.addSubview(banner)
        
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: 60),
            
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor)
        ])
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(openPhotoSettings))
        banner.addGestureRecognizer(tapGesture)
        
        // Adjust collection view
        collectionView.contentInset.top = 60
        collectionView.verticalScrollIndicatorInsets.top = 60
    }
    
    private func showPermissionDeniedAlert() {
        let alert = UIAlertController(
            title: NSLocalizedString("CustomPhotoPicker.PhotoAccessRequired", comment: ""),
            message: NSLocalizedString("CustomPhotoPicker.GrantAccessMessage", comment: ""),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("OpenSettings", comment: ""), style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        present(alert, animated: true)
    }
    
    @objc private func openPhotoSettings() {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self)
    }
    
    private func updateNavigationBar() {
        let hasSelection = viewModel.hasSelectedAssets
        navigationItem.rightBarButtonItem?.isEnabled = hasSelection
        title = hasSelection ? String(format: NSLocalizedString("CustomPhotoPicker.Selected", comment: ""), viewModel.selectionCount) : NSLocalizedString("CustomPhotoPicker.SelectPhotos", comment: "")
    }
    
    // MARK: - Cell Update Helpers
    private func updateVisibleSelectionNumbers() {
        // Only update selection numbers for visible cells when order changes
        for indexPath in collectionView.indexPathsForVisibleItems {
            if let asset = viewModel.getAsset(at: indexPath.item),
               let cell = collectionView.cellForItem(at: indexPath) as? PhotoCell {
                cell.selectionNumber = viewModel.getSelectionNumber(for: asset)
            }
        }
    }
    
    // MARK: - Actions
    @objc private func cancelTapped() {
        dismiss(animated: true)
    }
    
    @objc private func addTapped() {
        // Return the selected assets in order
        let orderedAssets = viewModel.selectedAssets.array
        onSelection?(orderedAssets)
        dismiss(animated: true)
    }
    
    // MARK: - Gesture Handling
    @objc private func handleTapGesture(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: location),
              let asset = viewModel.getAsset(at: indexPath.item) else { return }
        
        let wasSelected = viewModel.isAssetSelected(asset)
        let selectionChanged = viewModel.toggleAssetSelection(asset)
        
        guard selectionChanged else { return }
        
        // Update the specific cell that was tapped
        if let cell = collectionView.cellForItem(at: indexPath) as? PhotoCell {
            cell.isSelected = viewModel.isAssetSelected(asset)
            cell.selectionNumber = viewModel.getSelectionNumber(for: asset)
        }
        
        // Only update selection numbers if we removed an item (which affects ordering)
        if wasSelected {
            updateVisibleSelectionNumbers()
        }
    }
    
    @objc private func handleLongPressGesture(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else {
            // If we end the long press without moving, exit selection mode
            if gesture.state == .ended || gesture.state == .cancelled,
               viewModel.isInSelectionMode && !isSwipeSelecting {
                exitSelectionMode()
            }
            return
        }
        
        let location = gesture.location(in: collectionView)
        
        // Enter selection mode
        viewModel.enterSelectionMode()
        isSwipeSelecting = true
        processedIndexPaths.removeAll()
        lastProcessedIndexPath = nil
        feedbackGenerator.prepare()
        
        // Provide strong haptic feedback to indicate selection mode started
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // Determine selection mode based on initial cell
        if let indexPath = collectionView.indexPathForItem(at: location),
           let asset = viewModel.getAsset(at: indexPath.item) {
            swipeSelectionMode = viewModel.isAssetSelected(asset) ? .deselecting : .selecting
            processIndexPath(indexPath)
            lastProcessedIndexPath = indexPath
        }
    }
    
    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        // Only process pan gestures when in selection mode
        guard viewModel.isInSelectionMode else { return }
        
        switch gesture.state {
        case .began:
            isSwipeSelecting = true
            // Process the initial touch location
            let location = gesture.location(in: collectionView)
            if let indexPath = collectionView.indexPathForItem(at: location),
               !processedIndexPaths.contains(indexPath) {
                processIndexPath(indexPath)
                lastProcessedIndexPath = indexPath
            }
            
        case .changed:
            let location = gesture.location(in: collectionView)
            
            // Get the current index path under the finger
            guard let currentIndexPath = collectionView.indexPathForItem(at: location) else { return }
            
            // If we have a last processed index path, select all items between them
            if let lastIndexPath = lastProcessedIndexPath {
                let indexPaths = getIndexPathsBetween(from: lastIndexPath, to: currentIndexPath)
                
                // Process all index paths in the range that haven't been processed yet
                for indexPath in indexPaths {
                    if !processedIndexPaths.contains(indexPath) {
                        processIndexPath(indexPath)
                    }
                }
            } else {
                // No last index path, just process the current one
                if !processedIndexPaths.contains(currentIndexPath) {
                    processIndexPath(currentIndexPath)
                }
            }
            
            // Update the last processed index path
            lastProcessedIndexPath = currentIndexPath
            
        case .ended, .cancelled:
            exitSelectionMode()
            
        default:
            break
        }
    }
    
    private func exitSelectionMode() {
        isSwipeSelecting = false
        viewModel.exitSelectionMode()
        processedIndexPaths.removeAll()
        lastProcessedIndexPath = nil
    }
    
    // Helper method to get all index paths between two index paths in collection view order
    private func getIndexPathsBetween(from startIndexPath: IndexPath, to endIndexPath: IndexPath) -> [IndexPath] {
        var indexPaths: [IndexPath] = []
        
        let startIndex = startIndexPath.item
        let endIndex = endIndexPath.item
        
        // Determine the range
        let minIndex = min(startIndex, endIndex)
        let maxIndex = max(startIndex, endIndex)
        
        // Add all index paths in the range
        for index in minIndex...maxIndex {
            let indexPath = IndexPath(item: index, section: 0)
            indexPaths.append(indexPath)
        }
        
        return indexPaths
    }
    
    private func processIndexPath(_ indexPath: IndexPath) {
        guard let asset = viewModel.getAsset(at: indexPath.item) else { return }
        
        processedIndexPaths.insert(indexPath)
        
        var selectionChanged = false
        
        if swipeSelectionMode == .selecting {
            if viewModel.selectAsset(asset) {
                selectionChanged = true
            }
        } else {
            if viewModel.deselectAsset(asset) {
                selectionChanged = true
            }
        }
        
        // Provide haptic feedback when selection changes
        if selectionChanged {
            feedbackGenerator.impactOccurred()
            
            // Update the specific cell
            if let cell = collectionView.cellForItem(at: indexPath) as? PhotoCell {
                cell.isSelected = viewModel.isAssetSelected(asset)
                cell.selectionNumber = viewModel.getSelectionNumber(for: asset)
            }
            
            // Only update selection numbers if we removed an item (affects ordering)
            if swipeSelectionMode == .deselecting {
                updateVisibleSelectionNumbers()
            }
        }
    }
}

// MARK: - UICollectionView DataSource & Delegate
extension CustomPhotoPickerViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return viewModel.totalAssetCount
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PhotoCell", for: indexPath) as! PhotoCell
        
        guard let asset = viewModel.getAsset(at: indexPath.item) else { return cell }
        
        cell.configure(with: asset, imageManager: imageManager)
        
        // Configure selection state
        cell.isSelected = viewModel.isAssetSelected(asset)
        cell.selectionNumber = viewModel.getSelectionNumber(for: asset)
        
        return cell
    }
    

}

// MARK: - UIGestureRecognizerDelegate
extension CustomPhotoPickerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow long press and pan to work together
        return (gestureRecognizer is UILongPressGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer) ||
               (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UILongPressGestureRecognizer)
    }
    
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Pan gesture should only begin if we're in selection mode
        return !(gestureRecognizer is UIPanGestureRecognizer) || viewModel.isInSelectionMode
    }
}



// MARK: - Photo Cell
class PhotoCell: UICollectionViewCell {
    
    private let imageView = UIImageView()
    private let selectedOverlay = UIView()
    private let selectionNumberLabel = UILabel()
    private let videoIndicator = UILabel()
    private var imageRequestID: PHImageRequestID?
    
    var selectionNumber: Int? {
        didSet {
            if let number = selectionNumber {
                selectionNumberLabel.text = "\(number)"
                selectionNumberLabel.isHidden = false
            } else {
                selectionNumberLabel.isHidden = true
            }
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        // Image view
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        
        // Selected overlay
        selectedOverlay.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        selectedOverlay.isHidden = true
        contentView.addSubview(selectedOverlay)
        selectedOverlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            selectedOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            selectedOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            selectedOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            selectedOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        
        // Selection number label
        selectionNumberLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        selectionNumberLabel.textColor = .white
        selectionNumberLabel.backgroundColor = .systemBlue
        selectionNumberLabel.textAlignment = .center
        selectionNumberLabel.layer.cornerRadius = 12
        selectionNumberLabel.clipsToBounds = true
        selectionNumberLabel.isHidden = true
        contentView.addSubview(selectionNumberLabel)
        selectionNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            selectionNumberLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            selectionNumberLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            selectionNumberLabel.widthAnchor.constraint(equalToConstant: 24),
            selectionNumberLabel.heightAnchor.constraint(equalToConstant: 24)
        ])
        
        // Video indicator
        videoIndicator.font = .systemFont(ofSize: 12, weight: .medium)
        videoIndicator.textColor = .white
        videoIndicator.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        videoIndicator.textAlignment = .center
        videoIndicator.layer.cornerRadius = 4
        videoIndicator.clipsToBounds = true
        videoIndicator.isHidden = true
        contentView.addSubview(videoIndicator)
        videoIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            videoIndicator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            videoIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            videoIndicator.heightAnchor.constraint(equalToConstant: 20),
            videoIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }
    
    override var isSelected: Bool {
        didSet {
            selectedOverlay.isHidden = !isSelected
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        videoIndicator.isHidden = true
        isSelected = false
        selectionNumber = nil
        
        if let requestID = imageRequestID {
            PHImageManager.default().cancelImageRequest(requestID)
        }
    }
    
    func configure(with asset: PHAsset, imageManager: PHImageManager) {
        // Configure image
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        
        let targetSize = CGSize(width: bounds.width * UIScreen.main.scale,
                               height: bounds.height * UIScreen.main.scale)
        
        imageRequestID = imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            self?.imageView.image = image
        }
        
        // Configure video indicator
        configureVideoIndicator(for: asset)
    }
    
    private func configureVideoIndicator(for asset: PHAsset) {
        guard asset.mediaType == .video else {
            videoIndicator.isHidden = true
            return
        }
        
        videoIndicator.isHidden = false
        
        // Format duration
        let duration = asset.duration
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        videoIndicator.text = String(format: "%d:%02d", minutes, seconds)
    }
}

 
