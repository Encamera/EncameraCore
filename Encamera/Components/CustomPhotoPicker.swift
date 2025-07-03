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
        let viewController = CustomPhotoPickerViewController()
        viewController.onSelection = { assets in
            // Convert PHAssets to MediaSelectionResult
            let results = assets.map { asset in
                MediaSelectionResult.phAsset(asset)
            }
            selectedItems(results)
        }
        viewController.filter = filter
        viewController.selectionLimit = selectionLimit
        
        let navController = UINavigationController(rootViewController: viewController)
        navController.navigationBar.prefersLargeTitles = false
        return navController
    }
    
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        // Update if needed
    }
}



// MARK: - Custom Photo Picker View Controller
class CustomPhotoPickerViewController: UIViewController {
    
    // MARK: Properties
    var onSelection: (([PHAsset]) -> ())?
    var filter: PHPickerFilter = .images
    var selectionLimit: Int = 0
    
    private var collectionView: UICollectionView!
    private var assets: PHFetchResult<PHAsset>?
    private var selectedAssets = OrderedSet<PHAsset>()
    private var selectedIndexPaths = Set<IndexPath>()
    private let imageManager = PHCachingImageManager()
    
    private var isSwipeSelecting = false
    private var swipeSelectionMode: SwipeSelectionMode = .selecting
    private var processedIndexPaths = Set<IndexPath>()
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    
    private enum SwipeSelectionMode {
        case selecting
        case deselecting
    }
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupNavigationBar()
        setupCollectionView()
        checkPhotoLibraryPermission()
    }
    
    // MARK: - Setup
    private func setupNavigationBar() {
        title = "Select Photos"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Add",
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
        
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: "PhotoCell")
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.allowsMultipleSelection = true
        
        // Add pan gesture for swipe selection
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        panGesture.delegate = self
        collectionView.addGestureRecognizer(panGesture)
        
        view.addSubview(collectionView)
    }
    
    private func checkPhotoLibraryPermission() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized:
            loadPhotos()
        case .limited:
            loadPhotos()
            showLimitedAccessBanner()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                DispatchQueue.main.async {
                    if status == .authorized {
                        self?.loadPhotos()
                    } else if status == .limited {
                        self?.loadPhotos()
                        self?.showLimitedAccessBanner()
                    } else {
                        self?.showPermissionDeniedAlert()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionDeniedAlert()
        @unknown default:
            break
        }
    }
    
    private func showLimitedAccessBanner() {
        let banner = UIView()
        banner.backgroundColor = .systemYellow.withAlphaComponent(0.2)
        banner.translatesAutoresizingMaskIntoConstraints = false
        
        let label = UILabel()
        label.text = "Limited access. Tap here to select more photos or grant full access."
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
            title: "Photo Access Required",
            message: "Please grant full access to your photo library to use swipe selection. You can change this in Settings.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        present(alert, animated: true)
    }
    
    @objc private func openPhotoSettings() {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self)
    }
    
    private func loadPhotos() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // Apply filter
        if filter == .images {
            fetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        } else if filter == .videos {
            fetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        } else if filter == .any(of: [.images, .videos]) {
            fetchOptions.predicate = NSPredicate(format: "mediaType = %d OR mediaType = %d", 
                                               PHAssetMediaType.image.rawValue,
                                               PHAssetMediaType.video.rawValue)
        }
        
        assets = PHAsset.fetchAssets(with: fetchOptions)
        collectionView.reloadData()
    }
    
    private func updateNavigationBar() {
        if selectedAssets.isEmpty {
            navigationItem.rightBarButtonItem?.isEnabled = false
            title = "Select Photos"
        } else {
            navigationItem.rightBarButtonItem?.isEnabled = true
            title = "\(selectedAssets.count) Selected"
        }
    }
    
    // MARK: - Actions
    @objc private func cancelTapped() {
        dismiss(animated: true)
    }
    
    @objc private func addTapped() {
        // Return the selected assets in order
        let orderedAssets = selectedAssets.array
        onSelection?(orderedAssets)
        dismiss(animated: true)
    }
    
    // MARK: - Pan Gesture Handling
    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: collectionView)
        
        switch gesture.state {
        case .began:
            isSwipeSelecting = true
            processedIndexPaths.removeAll()
            feedbackGenerator.prepare()
            
            // Disable scrolling during swipe selection
            collectionView.isScrollEnabled = false
            
            // Determine selection mode based on initial cell
            if let indexPath = collectionView.indexPathForItem(at: location) {
                swipeSelectionMode = selectedIndexPaths.contains(indexPath) ? .deselecting : .selecting
                processIndexPath(indexPath)
            }
            
        case .changed:
            // Process all cells along the gesture path for smoother selection
            let translation = gesture.translation(in: collectionView)
            let startPoint = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            
            // Get all points along the line
            let points = interpolatePoints(from: startPoint, to: location, count: 10)
            
            for point in points {
                if let indexPath = collectionView.indexPathForItem(at: point),
                   !processedIndexPaths.contains(indexPath) {
                    processIndexPath(indexPath)
                }
            }
            
        case .ended, .cancelled:
            isSwipeSelecting = false
            processedIndexPaths.removeAll()
            // Re-enable scrolling
            collectionView.isScrollEnabled = true
            
        default:
            break
        }
    }
    
    // Helper method to interpolate points along a line
    private func interpolatePoints(from start: CGPoint, to end: CGPoint, count: Int) -> [CGPoint] {
        var points: [CGPoint] = []
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            points.append(CGPoint(x: x, y: y))
        }
        return points
    }
    
    private func processIndexPath(_ indexPath: IndexPath) {
        guard let asset = assets?[indexPath.item] else { return }
        
        processedIndexPaths.insert(indexPath)
        
        // Check selection limit
        if swipeSelectionMode == .selecting && selectionLimit > 0 && selectedAssets.count >= selectionLimit {
            return
        }
        
        var selectionChanged = false
        
        if swipeSelectionMode == .selecting {
            if !selectedAssets.contains(asset) {
                selectedAssets.append(asset)
                selectedIndexPaths.insert(indexPath)
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                selectionChanged = true
            }
        } else {
            if selectedAssets.contains(asset) {
                selectedAssets.remove(asset)
                selectedIndexPaths.remove(indexPath)
                collectionView.deselectItem(at: indexPath, animated: false)
                selectionChanged = true
            }
        }
        
        // Provide haptic feedback when selection changes
        if selectionChanged {
            feedbackGenerator.impactOccurred()
        }
        
        updateNavigationBar()
        
        // Update cell
        if let cell = collectionView.cellForItem(at: indexPath) as? PhotoCell {
            cell.isSelected = swipeSelectionMode == .selecting
            cell.selectionNumber = swipeSelectionMode == .selecting ? selectedAssets.firstIndex(of: asset).map { $0 + 1 } : nil
        }
    }
}

// MARK: - UICollectionView DataSource & Delegate
extension CustomPhotoPickerViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return assets?.count ?? 0
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PhotoCell", for: indexPath) as! PhotoCell
        
        if let asset = assets?[indexPath.item] {
            cell.configure(with: asset, imageManager: imageManager)
            cell.isSelected = selectedIndexPaths.contains(indexPath)
            cell.selectionNumber = selectedAssets.contains(asset) ? selectedAssets.firstIndex(of: asset).map { $0 + 1 } : nil
        }
        
        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isSwipeSelecting, let asset = assets?[indexPath.item] else { return }
        
        // Check selection limit
        if selectionLimit > 0 && selectedAssets.count >= selectionLimit && !selectedAssets.contains(asset) {
            collectionView.deselectItem(at: indexPath, animated: false)
            return
        }
        
        if !selectedAssets.contains(asset) {
            selectedAssets.append(asset)
        }
        selectedIndexPaths.insert(indexPath)
        updateNavigationBar()
        
        if let cell = collectionView.cellForItem(at: indexPath) as? PhotoCell {
            cell.selectionNumber = selectedAssets.firstIndex(of: asset).map { $0 + 1 }
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard !isSwipeSelecting, let asset = assets?[indexPath.item] else { return }
        
        selectedAssets.remove(asset)
        selectedIndexPaths.remove(indexPath)
        updateNavigationBar()
        
        // Update all cells' selection numbers
        for (index, remainingAsset) in selectedAssets.array.enumerated() {
            if let assetIndex = assets?.index(of: remainingAsset),
               let cell = collectionView.cellForItem(at: IndexPath(item: assetIndex, section: 0)) as? PhotoCell {
                cell.selectionNumber = index + 1
            }
        }
    }
}

// MARK: - UIGestureRecognizerDelegate
extension CustomPhotoPickerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow pan gesture to work simultaneously with collection view's scroll
        return true
    }
}

// MARK: - OrderedSet Helper
struct OrderedSet<T: Hashable> {
    private var _array: [T] = []
    private var set: Set<T> = []
    
    var array: [T] { _array }
    var count: Int { _array.count }
    var isEmpty: Bool { _array.isEmpty }
    
    mutating func append(_ element: T) {
        if !set.contains(element) {
            _array.append(element)
            set.insert(element)
        }
    }
    
    mutating func remove(_ element: T) {
        if let index = _array.firstIndex(of: element) {
            _array.remove(at: index)
            set.remove(element)
        }
    }
    
    func contains(_ element: T) -> Bool {
        return set.contains(element)
    }
    
    func firstIndex(of element: T) -> Int? {
        return _array.firstIndex(of: element)
    }
}

// MARK: - Photo Cell
class PhotoCell: UICollectionViewCell {
    
    private let imageView = UIImageView()
    private let selectedOverlay = UIView()
    private let selectedCheckmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private let selectionNumberLabel = UILabel()
    private let videoIndicator = UILabel()
    private var imageRequestID: PHImageRequestID?
    
    var selectionNumber: Int? {
        didSet {
            if let number = selectionNumber {
                selectionNumberLabel.text = "\(number)"
                selectionNumberLabel.isHidden = false
                selectedCheckmark.isHidden = true
            } else {
                selectionNumberLabel.isHidden = true
                selectedCheckmark.isHidden = !isSelected
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
        
        // Checkmark
        selectedCheckmark.tintColor = .systemBlue
        selectedCheckmark.isHidden = true
        contentView.addSubview(selectedCheckmark)
        selectedCheckmark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            selectedCheckmark.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            selectedCheckmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            selectedCheckmark.widthAnchor.constraint(equalToConstant: 24),
            selectedCheckmark.heightAnchor.constraint(equalToConstant: 24)
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
        videoIndicator.text = "Video"
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
            if selectionNumber == nil {
                selectedCheckmark.isHidden = !isSelected
            }
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
        
        // Show video indicator
        if asset.mediaType == .video {
            videoIndicator.isHidden = false
            
            // Show duration if available
            let duration = asset.duration
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            videoIndicator.text = String(format: "%d:%02d", minutes, seconds)
            
            // Adjust width to fit content
            videoIndicator.sizeToFit()
            videoIndicator.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                videoIndicator.widthAnchor.constraint(equalToConstant: max(44, videoIndicator.frame.width + 8))
            ])
        }
    }
}

 