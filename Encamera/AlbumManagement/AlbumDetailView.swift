import Combine
import EncameraCore
import SwiftUI
import SwiftUIIntrospect
import PhotosUI
import AVFoundation

@MainActor
class AlbumDetailViewModel<D: FileAccess>: ObservableObject, DebugPrintable {
    enum KeyViewerError {
        case couldNotSetKeychain
    }

    enum AlertType {
        case deleteAllAlbumData
        case deleteSelectedMedia
        case moveSelectedMedia(targetAlbum: Album)
        case hideAlbum
        case noLicenseDeletionWarning
        case photoAccessAlert
        case photoAccessDenied
    }

    enum ToastType {
        case albumCoverReset
        case albumCoverRemoved
        case mediaMovedSuccess(count: Int, albumName: String)

        var message: String {
            switch self {
            case .albumCoverReset:
                return L10n.AlbumDetailView.coverImageResetToast
            case .albumCoverRemoved:
                return L10n.AlbumDetailView.coverImageRemovedToast
            case .mediaMovedSuccess(let count, let albumName):
                return L10n.AlbumDetailView.movedToast("", "", "")
            }
        }
    }

    var appModalStateModel: AppModalStateModel?
    var albumManager: AlbumManaging

    @Published var keyViewerError: KeyViewerError?
    @Published var deleteActionError: String = ""
    @Published var isEditingAlbumName = false
    @Published var albumName: String = ""
    @Published var albumManagerError: String?
    @Published var showEmptyView: Bool = false
    @Published var isSelectingMedia: Bool = false
    @Published var selectedMedia: Set<InteractableMedia<EncryptedMedia>> = Set()
    @Published var isShowingPurchaseSheet = false
    @Published var activeAlert: AlertType? = nil
    @Published var activeToast: ToastType? = nil
    @Published var lastImportedAssets: [PHPickerResult] = []
    @Published var showPhotoPicker: ImportSource? = nil
    @Published var showImportProgressView: Bool = false {
        didSet {
            print("AlbumDetailView setting showProgressView \(showImportProgressView)")

        }
    }

    var agreedToDeleteWithNoLicense: Bool = false

    @Published var isAlbumHidden = false {
        didSet {
            guard let album = album else { return }
            albumManager.setIsAlbumHidden(isAlbumHidden, album: album)
        }
    }
    var afterPurchaseAction: (() -> Void)?
    var gridViewModel: GalleryGridViewModel<D>

    var purchasedPermissions: PurchasedPermissionManaging
    var fileManager: D
    private var importManager = BackgroundMediaImportManager.shared
    var album: Album? {
        didSet {
            prepareWithAlbum()
        }
    }

    var shouldCreateAlbum: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init(albumManager: AlbumManaging, fileManager: D = D.init(), album: Album?, purchasedPermissions: PurchasedPermissionManaging, shouldCreateAlbum: Bool = false) {
        self.albumManager = albumManager
        self.fileManager = fileManager
        self.purchasedPermissions = purchasedPermissions
        self.shouldCreateAlbum = shouldCreateAlbum
        self.isEditingAlbumName = shouldCreateAlbum
        let gridViewModel = GalleryGridViewModel<D>(album: album, albumManager: albumManager, blurImages: false, fileAccess: fileManager, purchasedPermissions: purchasedPermissions)
        self.gridViewModel = gridViewModel
        gridViewModel.$noMediaShown.sink { show in
            self.showEmptyView = show
        }.store(in: &cancellables)
        self.$isSelectingMedia.sink { isSelecting in
            gridViewModel.isSelectingMedia = isSelecting
        }.store(in: &cancellables)
        gridViewModel.$selectedMedia.sink { selected in
            self.selectedMedia = selected
        }.store(in: &cancellables)

        albumManager.albumOperationPublisher
            .receive(on: RunLoop.main)
            .sink { operation in
                switch operation {
                case .albumMoved(let album), .albumRenamed(let album):
                    Task { @MainActor in
                        self.album = album
                        await self.gridViewModel.enumerateMedia()
                    }
                default: break
                }
            }.store(in: &cancellables)
        
        // Dismiss photo picker when app goes to background
        NotificationUtils.didEnterBackgroundPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.showPhotoPicker = nil
            }
            .store(in: &cancellables)
        
        // Monitor import manager state for progress overlay
        importManager.$isImporting
            .receive(on: RunLoop.main)
            .sink { [weak self] isImporting in
                if isImporting && self?.showImportProgressView == false {
                    withAnimation(.easeIn(duration: 0.3)) {
                        self?.showImportProgressView = true
                    }
                }
            }
            .store(in: &cancellables)
        guard let album else { return }
        self.album = album

        prepareWithAlbum()

    }

    func prepareWithAlbum() {
        guard let album = album else { return }
        if purchasedPermissions.hasEntitlement == false {
            self.isAlbumHidden = false
        } else {
            self.isAlbumHidden = albumManager.isAlbumHidden(album)
        }
        self.albumName = album.name
        self.gridViewModel.album = album
        Task {
            self.fileManager = await D.init(for: album, albumManager: albumManager)
        }
    }

    func checkForLibraryPermissionsAndContinue() async throws {
        let status = PHPhotoLibrary.authorizationStatus()

        if status == .notDetermined {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.activeAlert = .photoAccessAlert
            }
        } else if status == .authorized || status == .limited {
            try await deleteMediaFromPhotoLibrary(result: lastImportedAssets)
        }
    }

    func removeAlbumCover() {
        guard let albumName = album?.name else { return }
        UserDefaultUtils.set("none", forKey: .albumCoverImage(albumName: albumName))
        showToast(type: .albumCoverRemoved)
        EventTracking.trackAlbumCoverRemoved()

    }

    func resetAlbumCover() {
        if let albumName = album?.name {
            UserDefaultUtils.set(nil, forKey: .albumCoverImage(albumName: albumName))
            showToast(type: .albumCoverReset)
            EventTracking.trackAlbumCoverReset()
        }
    }

    func requestPhotoLibraryPermission() async {
        if agreedToDeleteWithNoLicense == false && purchasedPermissions.hasEntitlement == false {
            activeAlert = .noLicenseDeletionWarning
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized:
            EventTracking.trackPhotoLibraryPermissionsGranted()
        case .limited:
            EventTracking.trackPhotoLibraryPermissionsLimited()
        default:
            EventTracking.trackPhotoLibraryPermissionsDenied()
        }
        try? await deleteMediaFromPhotoLibrary(result: lastImportedAssets)
    }
    
    func requestPhotoAccess() {
        Task {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            
            switch status {
            case .authorized, .limited:
                // Already have permission, show picker
                await MainActor.run {
                    self.showPhotoPicker = .photoLibrary
                }
            case .notDetermined:
                // Request permission
                let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                
                await MainActor.run {
                    switch newStatus {
                    case .authorized, .limited:
                        self.showPhotoPicker = .photoLibrary
                        
                        if newStatus == .limited {
                            // Track limited access
                            EventTracking.trackPhotoLibraryPermissionsLimited()
                        } else {
                            EventTracking.trackPhotoLibraryPermissionsGranted()
                        }
                    case .denied, .restricted:
                        // Show alert to open settings
                        self.showPhotoAccessDeniedAlert()
                        EventTracking.trackPhotoLibraryPermissionsDenied()
                    case .notDetermined:
                        // This shouldn't happen since we just requested permission, but handle it gracefully
                        break
                    @unknown default:
                        break
                    }
                }
            case .denied, .restricted:
                // Show alert to open settings
                await MainActor.run {
                    self.showPhotoAccessDeniedAlert()
                }
            @unknown default:
                break
            }
        }
    }
    
    private func showPhotoAccessDeniedAlert() {
        // We'll add a new alert type for this
        activeAlert = .photoAccessDenied
    }
    func handleSelectedFiles(urls: [URL]) {
        guard urls.count > 0 else {
            return
        }
        Task {
            // Convert URLs to CleartextMedia
            let media = urls.map { CleartextMedia(source: .url($0), generateID: true) }
            
            guard let albumId = album?.id else {
                debugPrint("No album ID available")
                return
            }
            
            do {
                // Use the new background import manager
                try await BackgroundMediaImportManager.shared.startImport(media: media, albumId: albumId)
                EventTracking.trackFilesImported(count: urls.count)
            } catch {
                debugPrint("Error starting import: \(error)")
            }
            
            await gridViewModel.enumerateMedia()
        }
    }

    private func loadMediaAsync(result: PHPickerResult) async throws -> [CleartextMedia] {
        // Identify whether the item is a video or an image
        let isLivePhoto = result.itemProvider.canLoadObject(ofClass: PHLivePhoto.self)
        if isLivePhoto {
            return try await loadLivePhoto(result: result)
        } else {
            return [try await loadMedia(result: result)]
        }
    }

    private func loadMedia(result: PHPickerResult) async throws -> CleartextMedia {
        let isVideo = result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let preferredType = isVideo ? UTType.movie.identifier : UTType.image.identifier

        let url: URL? = try await withCheckedThrowingContinuation { continuation in



            result.itemProvider.loadFileRepresentation(forTypeIdentifier: preferredType) { url, error in
                guard let url = url else {
                    debugPrint("Error loading file representation: \(String(describing: error))")
                    continuation.resume(returning: nil)
                    return
                }

                // Generate a unique file name to prevent overwriting existing files
                let fileName = NSUUID().uuidString + (isVideo ? ".mov" : ".jpeg")
                let destinationURL = URL.tempMediaDirectory.appendingPathComponent(fileName)

                do {
                    try FileManager.default.copyItem(at: url, to: destinationURL)
                    debugPrint("File copied to: \(destinationURL)")
                    continuation.resume(returning: destinationURL)
                } catch {
                    debugPrint("Error copying file: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }

        guard let url = url else {
            debugPrint("Error loading file representation, url is nil")
            throw ImportError.mismatchedType
        }

        return CleartextMedia(source: url, mediaType: isVideo ? .video : .photo, id: UUID().uuidString)
    }


    private func saveCleartextMedia(mediaArray: [CleartextMedia]) async throws {
        let media = try InteractableMedia(underlyingMedia: mediaArray)
        _ = try await fileManager.save(media: media) { progress in
            // Progress is now handled by BackgroundMediaImportManager
        }
    }

    private func loadLivePhoto(result: PHPickerResult) async throws -> [CleartextMedia] {

        let assetResources = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[PHAssetResource], Error>) in
            // Load the PHLivePhoto object from the picker result
            result.itemProvider.loadObject(ofClass: PHLivePhoto.self) { (object, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let livePhoto = object as? PHLivePhoto else {
                    continuation.resume(throwing: NSError(domain: "LivePhotoErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not load PHLivePhoto from the result"]))
                    return
                }

                continuation.resume(returning: PHAssetResource.assetResources(for: livePhoto))
            }
        }
        var cleartextMediaArray: [CleartextMedia] = []
        let id = UUID().uuidString

        for resource in assetResources {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            let documentsDirectory = URL.tempMediaDirectory
            let fileURL = documentsDirectory.appendingPathComponent(resource.originalFilename)
            do {
                var mediaType: MediaType
                switch resource.type {
                case .pairedVideo:
                    mediaType = .video
                case .photo:
                    mediaType = .photo
                default:
                    debugPrint("Error, could not handle media type \(resource.type)")
                    throw ImportError.mismatchedType
                }
                try await PHAssetResourceManager.default().writeData(for: resource, toFile: fileURL, options: options)
                let media = CleartextMedia(
                    source: fileURL,
                    mediaType: mediaType,
                    id: id
                )
                cleartextMediaArray.append(media)
            } catch {
                throw error
            }
        }

        return cleartextMediaArray
    }



    func handleSelectedMediaResults(_ results: [MediaSelectionResult]) {
        Task {
            var allMedia: [CleartextMedia] = []
            var pickerResults: [PHPickerResult] = []
            var assetIdentifiers: [String] = []

            for result in results {
                switch result {
                case .phAsset(let asset):
                    // Handle PHAsset directly
                    do {
                        let media = try await self.loadMediaFromAsset(asset)
                        allMedia.append(contentsOf: media)
                        
                        // Track the asset identifier
                        assetIdentifiers.append(asset.localIdentifier)
                        
                        // Track statistics
                        if asset.mediaType == .video {
                            UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
                        } else {
                            UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
                        }
                    } catch {
                        debugPrint("Error loading asset: \(error)")
                    }
                    
                case .phPickerResult(let pickerResult):
                    // Handle PHPickerResult
                    pickerResults.append(pickerResult)
                    
                    // Track the asset identifier if available
                    if let assetId = pickerResult.assetIdentifier {
                        assetIdentifiers.append(assetId)
                    }
                    
                    let provider = pickerResult.itemProvider
                    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                        UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
                    }
                    
                    // Collect media instead of saving immediately
                    do {
                        let media = try await self.loadMediaAsync(result: pickerResult)
                        allMedia.append(contentsOf: media)
                    } catch {
                        debugPrint("Error loading picker result: \(error)")
                    }
                }
            }
            
            // Use background import manager for all media at once
            guard let albumId = album?.id else {
                debugPrint("No album ID available")
                return
            }
            
            do {
                try await BackgroundMediaImportManager.shared.startImport(media: allMedia, albumId: albumId, assetIdentifiers: assetIdentifiers)
                EventTracking.trackMediaImported(count: results.count)
            } catch {
                debugPrint("Error starting import: \(error)")
            }
            
            // Only handle deletion for PHPickerResults
            if !pickerResults.isEmpty {
                lastImportedAssets = pickerResults
                try await checkForLibraryPermissionsAndContinue()
            }

            await gridViewModel.enumerateMedia()
        }
    }
    
    private func loadMediaFromAsset(_ asset: PHAsset) async throws -> [CleartextMedia] {
        // Handle live photos
        if asset.mediaSubtypes.contains(.photoLive) {
            return try await loadLivePhotoFromAsset(asset)
        } else {
            return [try await loadRegularMediaFromAsset(asset)]
        }
    }
    
    private func loadRegularMediaFromAsset(_ asset: PHAsset) async throws -> CleartextMedia {
        let isVideo = asset.mediaType == .video
        let id = UUID().uuidString
        
        if isVideo {
            // Handle video
            return try await withCheckedThrowingContinuation { continuation in
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.version = .current
                
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    guard let urlAsset = avAsset as? AVURLAsset else {
                        continuation.resume(throwing: ImportError.mismatchedType)
                        return
                    }
                    
                    let fileName = id + ".mov"
                    let destinationURL = URL.tempMediaDirectory.appendingPathComponent(fileName)
                    
                    do {
                        try FileManager.default.copyItem(at: urlAsset.url, to: destinationURL)
                        let media = CleartextMedia(source: destinationURL, mediaType: .video, id: id)
                        continuation.resume(returning: media)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } else {
            // Handle image
            return try await withCheckedThrowingContinuation { continuation in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.version = .current
                
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    guard let data = data else {
                        continuation.resume(throwing: ImportError.mismatchedType)
                        return
                    }
                    
                    let fileName = id + ".jpeg"
                    let destinationURL = URL.tempMediaDirectory.appendingPathComponent(fileName)
                    
                    do {
                        try data.write(to: destinationURL)
                        let media = CleartextMedia(source: destinationURL, mediaType: .photo, id: id)
                        continuation.resume(returning: media)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    private func loadLivePhotoFromAsset(_ asset: PHAsset) async throws -> [CleartextMedia] {
        let resources = PHAssetResource.assetResources(for: asset)
        var cleartextMediaArray: [CleartextMedia] = []
        let id = UUID().uuidString
        
        for resource in resources {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            
            let documentsDirectory = URL.tempMediaDirectory
            let fileURL = documentsDirectory.appendingPathComponent(resource.originalFilename)
            
            var mediaType: MediaType
            switch resource.type {
            case .pairedVideo:
                mediaType = .video
            case .photo:
                mediaType = .photo
            default:
                debugPrint("Error, could not handle media type \(resource.type)")
                continue
            }
            
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: fileURL, options: options)
            let media = CleartextMedia(
                source: fileURL,
                mediaType: mediaType,
                id: id
            )
            cleartextMediaArray.append(media)
        }
        
        return cleartextMediaArray
    }

    func handleSelectedMedia(items: [PHPickerResult]) {
        // Convert to MediaSelectionResult and call the new method
        let results = items.map { MediaSelectionResult.phPickerResult($0) }
        handleSelectedMediaResults(results)
    }



    private func deleteMediaFromPhotoLibrary(result: [PHPickerResult]) async throws {

        let assetIdentifier = result.compactMap({$0.assetIdentifier})

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifier, options: nil)

        if assets.count > 0 {
            do {
                try await PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets(assets)
                })
                debugPrint("Media successfully deleted from Photo Library")
                EventTracking.trackMediaDeleted(count: assets.count)
            } catch {
                debugPrint("Failed to delete media: \(error)")
            }
        } else {
            debugPrint("No assets found to delete")
        }
    }

    func setAlbumNameFromInput() {
        guard albumName.count > 0 else {
            albumManagerError = L10n.pleaseEnterAnAlbumName
            albumName = album?.name ?? L10n.defaultAlbumName
            return
        }
        do {
            if shouldCreateAlbum {
                album = try albumManager.create(name: albumName, storageOption: albumManager.defaultStorageForAlbum)
            } else if let album {
                self.album = try albumManager.renameAlbum(album: album, to: albumName)
            }
        } catch {
            if let albumError = error as? AlbumError, albumError == AlbumError.albumExists {
                albumManagerError = L10n.albumExistsError
            } else {
                albumManagerError = L10n.couldNotRenameAlbumError
            }
        }
    }

    func deleteAlbum() {
        guard let album else { return }
        albumManager.delete(album: album)
    }
    
    /// Clears selection mode and selected media, then refreshes the grid
    @MainActor
    private func clearSelectionAndRefreshGrid() {
        // Clear selection state
        gridViewModel.isSelectingMedia = false
        gridViewModel.selectedMedia.removeAll()
        isSelectingMedia = false
        selectedMedia.removeAll()
        
        // Refresh grid view (only use this method for cases where FileOperationBus won't handle it)
        Task {
            await gridViewModel.enumerateMedia()
        }
    }

    func deleteSelectedMedia() {
        Task {
            // Store the selected items before clearing selection
            let itemsToDelete = Array(selectedMedia)
            
            // First, exit selection mode
            await MainActor.run {
                gridViewModel.selectedMedia.removeAll()
                gridViewModel.isSelectingMedia = false
                isSelectingMedia = false
            }
            
            // Delete the files - this will trigger FileOperationBus with animated removal
            do {
                try await fileManager.delete(media: itemsToDelete)
                // No need to manually refresh - FileOperationBus will handle the animation
            } catch {
                printDebug("Error deleting media: \(error)")
                // On error, refresh to ensure consistency
                await MainActor.run {
                    Task {
                        await gridViewModel.enumerateMedia()
                    }
                }
            }
        }
    }

    func canDeleteKey() -> Bool {
        return true
    }

    func moveAlbum(to storage: StorageType) {
        guard let album else { return }
        self.album = try? albumManager.moveAlbum(album: album, toStorage: storage)
        EventTracking.trackConfirmStorageTypeSelected(type: storage)
    }

    var currentSharingData: Any?

    @MainActor
    func shareSheet(data: [Any]) {
        self.currentSharingData = data

        let activityView = UIActivityViewController(activityItems: data + [self], applicationActivities: nil)
        activityView.completionWithItemsHandler = { activityType, completed, returnedItems, error in
            if let error = error {
                print("Share error: \(error.localizedDescription)")
            }
            self.currentSharingData = nil
            EventTracking.trackMediaShared(count: data.count)
        }

        let allScenes = UIApplication.shared.connectedScenes
        let scene = allScenes.first { $0.activationState == .foregroundActive }

        if let windowScene = scene as? UIWindowScene {
            windowScene.keyWindow?.rootViewController?.present(activityView, animated: true, completion: nil)
        }
    }

    func selectAllMedia() {
        gridViewModel.selectedMedia = Set(gridViewModel.media)
    }

    func shareSelected() {
        let sharingUtil = ShareMediaUtil(fileAccess: fileManager, targetMedia: Array(selectedMedia))
        Task {
            do {
                try await sharingUtil.prepareSharingData { status in
                    self.printDebug("Prepare sharing status: \(status)")
                }
                Task { @MainActor in
                    do {
                        try await sharingUtil.showShareSheet()
                    } catch {
                        self.printDebug("Error sharing: \(error)")
                    }
                }
            } catch {
                self.printDebug("Error preparing sharing data: \(error)")
            }
        }
    }

    func showToast(type: ToastType) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation {
                self.activeToast = type
            }
        }
    }
    
    func showMoveAlbumModal() {
        guard let currentAlbum = album else { return }
        let availableAlbums = Array(albumManager.albums).filter { $0.id != currentAlbum.id }
        
        let context = AlbumSelectionContext(
            sourceView: "AlbumDetailView",
            availableAlbums: availableAlbums,
            currentAlbum: currentAlbum,
            selectedMedia: selectedMedia,
            onAlbumSelected: { selectedAlbum in
                self.confirmMoveToAlbum(selectedAlbum)
            },
            onDismiss: {
                self.appModalStateModel?.currentModal = nil
            }
        )
        
        appModalStateModel?.currentModal = .albumSelection(context: context)
    }
    
    private func confirmMoveToAlbum(_ targetAlbum: Album) {
        // Close the modal first
        appModalStateModel?.currentModal = nil
        // Show confirmation alert
        activeAlert = .moveSelectedMedia(targetAlbum: targetAlbum)
    }
    
    func moveSelectedMedia(to targetAlbum: Album) {
        Task {
            // Store the selected items before clearing selection
            let itemsToMove = Array(selectedMedia)
            var completedItems: [InteractableMedia<EncryptedMedia>] = []
            var failedItems: [InteractableMedia<EncryptedMedia>] = []
            
            // First, exit selection mode
            await MainActor.run {
                gridViewModel.selectedMedia.removeAll()
                gridViewModel.isSelectingMedia = false
                isSelectingMedia = false
            }
            
            // Create a new file manager configured for the target album
            let targetFileManager = await D.init(for: targetAlbum, albumManager: albumManager)
            
            // First, copy all media to target album
            for media in itemsToMove {
                do {
                    try await targetFileManager.copy(media: media)
                    completedItems.append(media)
                } catch {
                    printDebug("Error copying media: \(error)")
                    failedItems.append(media)
                }
            }
            
            // Then, batch delete successfully copied items from source album and send move notification
            if !completedItems.isEmpty {
                do {
                    // Extract the underlying encrypted media for the notification
                    let movedEncryptedMedia = completedItems.flatMap { $0.underlyingMedia }
                    
                    // Send move notification BEFORE deletion to ensure proper animation
                    FileOperationBus.shared.didMove(movedEncryptedMedia, to: targetAlbum)
                    
                    // Then delete from source (this won't trigger additional animation since we already notified about move)
                    try await fileManager.delete(media: completedItems)
                } catch {
                    printDebug("Error deleting media after move: \(error)")
                    // On error, refresh to ensure consistency
                    await MainActor.run {
                        Task {
                            await gridViewModel.enumerateMedia()
                        }
                    }
                }
            }
            
            // Show toast for successful moves
            await MainActor.run {
                if completedItems.count > 0 {
                    showToast(type: .mediaMovedSuccess(count: completedItems.count, albumName: targetAlbum.name))
                }
                
                // Show error if some failed
                if failedItems.count > 0 {
                    // Could add an error toast type here in the future
                    printDebug("Failed to move \(failedItems.count) items")
                }
            }
        }
    }
}

struct AlbumDetailView<D: FileAccess>: View {
    @State var isShowingMoveAlbumModal = false

    @StateObject var viewModel: AlbumDetailViewModel<D>
    @Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject var appModalStateModel: AppModalStateModel
    @FocusState private var isAlbumNameFocused: Bool

    func popLastView() {
        presentationMode.wrappedValue.dismiss()
    }



    var body: some View {

        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Group {
                    GalleryGridView(viewModel: viewModel.gridViewModel) {
                        VStack {
                            if viewModel.showEmptyView {
                                emptyState
                            }
                        }

                    }
                }
                .environmentObject(appModalStateModel)
                .chooseStorageModal(isPresented: $isShowingMoveAlbumModal,
                                    album: viewModel.album,
                                    purchasedPermissions: viewModel.purchasedPermissions, didSelectStorage: { storage, hasEntitlement in
                    if hasEntitlement || storage == .local {
                        viewModel.moveAlbum(to: storage)
                        isShowingMoveAlbumModal = false
                    } else if !hasEntitlement && storage == .icloud {

                        viewModel.isShowingPurchaseSheet = true
                        viewModel.afterPurchaseAction = {
                            viewModel.moveAlbum(to: storage)
                        }
                    }
                }, dismissAction: {
                    isShowingMoveAlbumModal = false
                })
                .productStorefront(isPresented: $viewModel.isShowingPurchaseSheet, fromViewName: "AlbumDetailView") { action in
                    if case .purchaseComplete = action {
                        isShowingMoveAlbumModal = false
                        viewModel.afterPurchaseAction?()
                        Task {
                            await viewModel.gridViewModel.enumerateMedia()
                        }
                    } else {
                        viewModel.isShowingPurchaseSheet = false
                    }
                }
                
                if viewModel.isSelectingMedia {
                    selectionTray
                }
            }
            
            // Import progress overlay
            if viewModel.showImportProgressView {
                VStack {
                    Spacer()
                    GlobalImportProgressView(viewModel: .init(deleteEnabled: true), showProgressView: $viewModel.showImportProgressView)
                        .padding(.horizontal, 16)
                    Spacer().frame(height: 26)
                }
                .ignoresSafeArea(edges: .top)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbarRole(.editor)
        .toolbar(content: {
            ToolbarItemGroup(placement: .principal, content: {
                horizontalTitleComponents
            })
        })
        .alert(isPresented: Binding<Bool>(
            get: { viewModel.activeAlert != nil },
            set: { if !$0 { viewModel.activeAlert = nil } }
        )) {
            alert(for: viewModel.activeAlert)
        }
        .sheet(isPresented: Binding<Bool>(get: {
            viewModel.showPhotoPicker != nil
        }, set: { newValue in
            viewModel.showPhotoPicker = nil
        }), content: {
            switch viewModel.showPhotoPicker {
            case .photoLibrary:
                // Always use PhotoPickerWrapper which automatically selects the best picker
                // based on photo library permissions (custom picker with swipe for full access,
                // standard picker for limited access)
                PhotoPickerWrapper(selectedItems: { results in
                    viewModel.handleSelectedMediaResults(results)
                }, filter: .any(of: [.images, .videos, .livePhotos]))
                .ignoresSafeArea(.all)
            case .files:
                FilePicker { urls in
                    viewModel.handleSelectedFiles(urls: urls)
                }
            case .none:
                EmptyView()
            }
        })
        .toast(isShowing: Binding<Bool>(get: {
            let showing = viewModel.activeToast != nil
            return showing
        }, set: { value in
            if value == false {
                viewModel.activeToast = nil
            }
        }), message: viewModel.activeToast?.message ?? "")
        .gradientBackground()
        .ignoresSafeArea(edges: [.bottom])
        .screenBlocked()
        .onAppear {
            viewModel.appModalStateModel = appModalStateModel
            // Focus the text field if we're creating a new album
            if viewModel.shouldCreateAlbum {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isAlbumNameFocused = true
                }
            }
        }
        .onChange(of: viewModel.isEditingAlbumName) { oldValue, newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isAlbumNameFocused = true
                }
            } else {
                isAlbumNameFocused = false
            }
        }

    }


    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {

            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Spacer().frame(height: 65)
                    ImageWithBackgroundRectangle(imageName: "Album-Camera",
                                                 rectWidth: 94,
                                                 rectHeight: 94,
                                                 rectCornerRadius: 24,
                                                 rectOpacity: 0.10)
                    Spacer().frame(height: 28)
                    Group {
                        Text(L10n.AlbumDetailView.addFirstImage)
                            .fontType(.pt24, weight: .bold)
                        Text(L10n.AlbumDetailView.addFirstImageSubtitle)
                            .multilineTextAlignment(.center)
                            .lineLimit(2, reservesSpace: true)
                            .fontType(.pt14)
                            .opacity(0.60)
                    }.frame(alignment: .center)

                }
            }.frame(maxWidth: .infinity)
            Spacer().frame(maxHeight: .infinity)
            DualButtonComponent(nextActive: .constant(false),
                                bottomButtonTitle: L10n.AlbumDetailView.importButton,
                                bottomButtonAction: {
                viewModel.requestPhotoAccess()
            },
                                secondaryButtonTitle: L10n.AlbumDetailView.openCamera,
                                secondaryButtonAction: {
                guard let album = viewModel.album else { return }
                appModalStateModel.currentModal = .cameraView(context: .init(sourceView: "AlbumDetailView", album: album, closeButtonTapped: { _ in
                    Task {
                        await viewModel.gridViewModel.enumerateMedia()
                    }
                }))
            })
            Spacer().frame(height: 8)
        }.padding()
    }



    var horizontalTitleComponents: some View {
        Group {
            if viewModel.isEditingAlbumName {
                ViewHeader(isToolbar: true, centerContent: {
                    TextField(L10n.albumName, text: $viewModel.albumName)
                        .focused($isAlbumNameFocused)
                        .fontType(.pt18, weight: .bold)
                        .noAutoModification()
                }, rightContent: {
                    HStack(alignment: .center) {
                        Button {
                            viewModel.albumName = viewModel.album?.name ?? ""
                            viewModel.isEditingAlbumName = false
                            if viewModel.albumName == "" {
                                popLastView()
                            }
                        } label: {
                            Text(L10n.cancel)
                                .fontType(.pt14, weight: .bold)
                        }

                        Button {
                            viewModel.setAlbumNameFromInput()
                            viewModel.isEditingAlbumName = false
                        } label: {
                            Text(L10n.save)
                                .fontType(.pt14, weight: .bold)
                        }
                    }
                })
            } else  {
                ViewHeader(title: viewModel.albumName, isToolbar: true,
                           textAlignment: .center,
                           titleFont: .pt18,
                           rightContent: {
                    HStack(alignment: .center) {
                        if viewModel.isSelectingMedia {
                            Button {
                                viewModel.isSelectingMedia = false
                            } label: {
                                Text(L10n.cancel)
                                    .fontType(.pt14, weight: .bold)
                            }
                        } else {
                            buttonMenu
                        }
                    }
                })
                .transition(.slide)
            }
        }
    }
    var buttonMenu: some View {
        Menu {
            if viewModel.gridViewModel.media.count > 0 {
                Button {
                    viewModel.isSelectingMedia = true
                } label: {
                    Text(L10n.AlbumDetailView.select)
                        .fontType(.pt14, weight: .bold)
                }
            }
            Button(L10n.moveAlbumStorage) {
                isShowingMoveAlbumModal = true
            }
            Button(L10n.viewInFiles) {
                LocalDeeplinkingUtils.openAlbumContentsInFiles(albumManager: viewModel.albumManager, album: viewModel.album!)
            }
            Button(L10n.rename) {
                viewModel.isEditingAlbumName = true
            }

            Button(L10n.importFromPhotos) {
                viewModel.requestPhotoAccess()
            }

            Button(L10n.importFromFiles) {
                viewModel.showPhotoPicker = .files
            }
            Button {
                if viewModel.purchasedPermissions.hasEntitlement == false {
                    viewModel.isShowingPurchaseSheet = true
                    viewModel.afterPurchaseAction = {
                        viewModel.activeAlert = .hideAlbum
                    }
                } else if viewModel.isAlbumHidden {
                    viewModel.isAlbumHidden = false
                } else {
                    viewModel.activeAlert = .hideAlbum
                }
            } label: {
                HStack {
                    Text(L10n.AlbumDetailView.hideAlbumMenuItem)
                    Spacer()
                    if viewModel.isAlbumHidden {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Menu(L10n.AlbumDetailView.albumCoverMenuTitle) {
                Button(L10n.AlbumDetailView.removeCoverImage) {
                    if viewModel.purchasedPermissions.hasEntitlement {
                        viewModel.removeAlbumCover()
                    } else {
                        self.appModalStateModel.currentModal = .purchaseView(context: .init(sourceView: "AlbumDetailView", purchaseAction: { action in
                            if case .purchaseComplete = action {
                                viewModel.removeAlbumCover()
                            }
                        }))
                    }
                }
                if let albumName = viewModel.album?.name, UserDefaultUtils.string(forKey: .albumCoverImage(albumName: albumName)) != nil {
                    Button(L10n.AlbumDetailView.resetCoverImage) {
                        viewModel.resetAlbumCover()
                    }
                }
            }
            Button(L10n.deleteAlbum, role: .destructive) {
                viewModel.activeAlert = .deleteAllAlbumData
            }

        } label: {
            Image("Album-OptionsDots")
        }
    }


    var selectionTray: some View {

        return MediaSelectionTray(shareAction: {
            viewModel.shareSelected()
        }, deleteAction: {
            viewModel.activeAlert = .deleteSelectedMedia
        }, moveAction: {
            viewModel.showMoveAlbumModal()
        }, selectAllAction: {
            viewModel.selectAllMedia()
        }, selectedMedia: $viewModel.selectedMedia, showShareOption: .constant(true))
    }

    private func alert(for alertType: AlbumDetailViewModel<D>.AlertType?) -> Alert {
        switch alertType {
        case .deleteAllAlbumData:
            return Alert(
                title: Text(L10n.deleteAllAssociatedData),
                message: Text(viewModel.deleteActionError),
                primaryButton: .destructive(Text(L10n.deleteEverything)) {
                    viewModel.deleteAlbum()
                    popLastView()
                },
                secondaryButton: .cancel(Text(L10n.cancel))
            )
        case .deleteSelectedMedia:
            return Alert(
                title: Text(L10n.AlbumDetailView.confirmDeletion),
                message: Text(L10n.AlbumDetailView.deleteSelectedMedia(L10n.imageS(viewModel.selectedMedia.count))),
                primaryButton: .destructive(Text(L10n.delete)) {
                    viewModel.deleteSelectedMedia()
                },
                secondaryButton: .cancel(Text(L10n.cancel))
            )
        case .moveSelectedMedia(let targetAlbum):
            return Alert(
                title: Text(L10n.AlbumDetailView.moveMedia),
                message: Text(L10n.AlbumDetailView.moveMediaConfirm("", "", "")),
                primaryButton: .default(Text(L10n.AlbumDetailView.moveMedia)) {
                    viewModel.moveSelectedMedia(to: targetAlbum)
                },
                secondaryButton: .cancel(Text(L10n.cancel))
            )
        case .hideAlbum:
            return Alert(
                title: Text(L10n.AlbumDetailView.hideAlbumAlertTitle),
                message: Text(L10n.AlbumDetailView.hideAlbumAlertMessage),
                primaryButton: .destructive(Text(L10n.hide)) {
                    viewModel.isAlbumHidden = true
                },
                secondaryButton: .cancel(Text(L10n.cancel))
            )
        case .noLicenseDeletionWarning:
            return Alert(
                title: Text(L10n.AlbumDetailView.noLicenseDeletionWarningTitle),
                message: Text(L10n.AlbumDetailView.noLicenseDeletionWarningMessage),
                primaryButton: .cancel(Text(L10n.cancel)),
                secondaryButton: .destructive(Text(L10n.AlbumDetailView.noLicenseDeletionWarningPrimaryButton)) {
                    viewModel.agreedToDeleteWithNoLicense = true
                    Task {
                        await viewModel.requestPhotoLibraryPermission()
                    }
                }
            )
        case .photoAccessAlert:
            return Alert(
                title: Text(L10n.AlbumDetailView.photoAccessAlertTitle),
                message: Text(L10n.AlbumDetailView.photoAccessAlertMessage),
                primaryButton: .destructive(Text(L10n.AlbumDetailView.photoAccessAlertPrimaryButton)) {
                    Task {
                        await viewModel.requestPhotoLibraryPermission()
                    }
                },
                secondaryButton: .cancel(Text(L10n.AlbumDetailView.photoAccessAlertSecondaryButton))
            )
        case .photoAccessDenied:
            return Alert(
                title: Text(L10n.AlbumDetailView.photoAccessRequired),
                message: Text(L10n.AlbumDetailView.photoAccessSettings),
                primaryButton: .default(Text(L10n.AlbumDetailView.openSettings)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                },
                secondaryButton: .cancel(Text(L10n.cancel))
            )
        case .none:
            return Alert(title: Text(""))
        }
    }
}

#Preview {
    NavigationStack {
        AlbumDetailView<DemoFileEnumerator>(viewModel: .init(albumManager: DemoAlbumManager(), fileManager: DemoFileEnumerator(), album: DemoAlbumManager().currentAlbum, purchasedPermissions: DemoPurchasedPermissionManaging()))
            .environmentObject(AppModalStateModel())
    }
}
