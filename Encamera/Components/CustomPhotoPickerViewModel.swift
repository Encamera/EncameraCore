import SwiftUI
import Photos
import PhotosUI
import Combine
import AVFoundation

// MARK: - Photo Picker ViewModel
@MainActor
class CustomPhotoPickerViewModel: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var assets: PHFetchResult<PHAsset>?
    @Published var selectedAssets = OrderedSet<PHAsset>()
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isInSelectionMode = false
    @Published var selectionCount: Int = 0
    
    // MARK: - Configuration
    var filter: PHPickerFilter = .images
    var selectionLimit: Int = 0 // 0 for unlimited
    
    // MARK: - Private Properties
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    override init() {
        super.init()
        
        // Update selection count when selectedAssets changes
        $selectedAssets
            .map { $0.count }
            .assign(to: \.selectionCount, on: self)
            .store(in: &cancellables)
        
        // Register as photo library observer
        PHPhotoLibrary.shared().register(self)
        
        checkPhotoLibraryPermission()
    }
    
    deinit {
        // Unregister from photo library observations
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    // MARK: - Photo Library Authorization
    func checkPhotoLibraryPermission() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch authorizationStatus {
        case .authorized, .limited:
            loadPhotos()
        case .notDetermined:
            requestPhotoLibraryPermission()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }
    
    func requestPhotoLibraryPermission() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                if status == .authorized || status == .limited {
                    self?.loadPhotos()
                }
            }
        }
    }
    
    // MARK: - Asset Loading
    func loadPhotos() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // Apply filter based on PHPickerFilter
        // Note: PHPickerFilter is more complex than simple enum cases, so we'll apply basic filtering
        // For now, we'll support basic image/video filtering and default to all media types
        if filter == .images {
            fetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        } else if filter == .videos {
            fetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        } else {
            // For any other filter, include both images and videos
            fetchOptions.predicate = NSPredicate(format: "mediaType = %d OR mediaType = %d",
                                               PHAssetMediaType.image.rawValue,
                                               PHAssetMediaType.video.rawValue)
        }
        
        assets = PHAsset.fetchAssets(with: fetchOptions)
    }
    
    // MARK: - Selection Management
    func canSelectAsset(_ asset: PHAsset) -> Bool {
        // Check if we can select more assets based on limit
        if selectionLimit > 0 && selectedAssets.count >= selectionLimit && !selectedAssets.contains(asset) {
            return false
        }
        return true
    }
    
    func selectAsset(_ asset: PHAsset) -> Bool {
        guard canSelectAsset(asset) else { return false }
        
        if !selectedAssets.contains(asset) {
            selectedAssets.append(asset)
            return true
        }
        return false
    }
    
    func deselectAsset(_ asset: PHAsset) -> Bool {
        if selectedAssets.contains(asset) {
            selectedAssets.remove(asset)
            return true
        }
        return false
    }
    
    func toggleAssetSelection(_ asset: PHAsset) -> Bool {
        if selectedAssets.contains(asset) {
            return deselectAsset(asset)
        } else {
            return selectAsset(asset)
        }
    }
    
    func isAssetSelected(_ asset: PHAsset) -> Bool {
        return selectedAssets.contains(asset)
    }
    
    func getSelectionNumber(for asset: PHAsset) -> Int? {
        return selectedAssets.firstIndex(of: asset).map { $0 + 1 }
    }
    
    func clearSelection() {
        selectedAssets = OrderedSet<PHAsset>()
    }
    
    // MARK: - Selection Mode Management
    func enterSelectionMode() {
        isInSelectionMode = true
    }
    
    func exitSelectionMode() {
        isInSelectionMode = false
    }
    
    // MARK: - Batch Selection
    func selectAssets(_ assets: [PHAsset]) -> [PHAsset] {
        var successfullySelected: [PHAsset] = []
        
        for asset in assets {
            if selectAsset(asset) {
                successfullySelected.append(asset)
            }
        }
        
        return successfullySelected
    }
    
    func deselectAssets(_ assets: [PHAsset]) -> [PHAsset] {
        var successfullyDeselected: [PHAsset] = []
        
        for asset in assets {
            if deselectAsset(asset) {
                successfullyDeselected.append(asset)
            }
        }
        
        return successfullyDeselected
    }
    
    // MARK: - Validation
    var hasSelectedAssets: Bool {
        return !selectedAssets.isEmpty
    }
    
    var isAtSelectionLimit: Bool {
        return selectionLimit > 0 && selectedAssets.count >= selectionLimit
    }
    
    var remainingSelectionCount: Int {
        if selectionLimit <= 0 {
            return Int.max // Unlimited
        }
        return max(0, selectionLimit - selectedAssets.count)
    }
    
    // MARK: - Asset Information
    func getAsset(at index: Int) -> PHAsset? {
        guard let assets = assets, index >= 0 && index < assets.count else {
            return nil
        }
        return assets[index]
    }
    
    var totalAssetCount: Int {
        return assets?.count ?? 0
    }
    
    // MARK: - Configuration Updates
    func updateFilter(_ newFilter: PHPickerFilter) {
        filter = newFilter
        loadPhotos()
    }
    
    func updateSelectionLimit(_ newLimit: Int) {
        selectionLimit = newLimit
        
        // If new limit is lower than current selection, trim selection
        if newLimit > 0 && selectedAssets.count > newLimit {
            let assetsToRemove = Array(selectedAssets.array.suffix(selectedAssets.count - newLimit))
            for asset in assetsToRemove {
                selectedAssets.remove(asset)
            }
        }
    }
}

// MARK: - PHPhotoLibraryChangeObserver
extension CustomPhotoPickerViewModel: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard let assets = self.assets else { return }
            
            // Check if our fetch result has changes
            if let changeDetails = changeInstance.changeDetails(for: assets) {
                // Update the fetch result
                self.assets = changeDetails.fetchResultAfterChanges
                
                // Update selected assets to remove any that are no longer available
                let removedAssets = changeDetails.removedObjects
                for removedAsset in removedAssets {
                    self.selectedAssets.remove(removedAsset)
                }
                
                // If we have insertions, the user added photos to the limited library
                // If we have removals, the user removed photos from the limited library
                // In both cases, the UI will automatically update due to @Published property
            } else {
                // If no specific changes, reload all photos to catch any permission changes
                // This is especially important for limited library access changes
                self.loadPhotos()
            }
        }
    }
}



// MARK: - OrderedSet Helper (moved from original file)
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