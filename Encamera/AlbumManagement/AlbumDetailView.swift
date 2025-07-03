import Combine
import EncameraCore
import SwiftUI
import SwiftUIIntrospect
import PhotosUI

import SwiftUI

@MainActor
class AlbumDetailViewModel<D: FileAccess>: ObservableObject, DebugPrintable {
    enum KeyViewerError {
        case couldNotSetKeychain
    }

    enum AlertType {
        case deleteAllAlbumData
        case deleteSelectedMedia
        case hideAlbum
        case noLicenseDeletionWarning
        case photoAccessAlert
    }

    enum ToastType {
        case albumCoverReset
        case albumCoverRemoved

        var message: String {
            switch self {
            case .albumCoverReset:
                return L10n.AlbumDetailView.coverImageResetToast
            case .albumCoverRemoved:
                return L10n.AlbumDetailView.coverImageRemovedToast
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
    @Published var selectedPhotoPickerItems: [PhotosPickerItem] = []

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
        FileOperationBus.shared.operations.sink { operation in
            if self.purchasedPermissions.hasEntitlement == false {
                Task { @MainActor in
                    self.appModalStateModel?.currentModal = .purchaseView(context: .init(sourceView: "AlbumDetailView", purchaseAction: { action in
                        if case .purchaseComplete = action {
                            self.appModalStateModel?.currentModal = nil
                        }
                    }))
                }
            }
            Task {
                await self.gridViewModel.enumerateMedia()
            }
        }.store(in: &cancellables)
        Task {
            self.fileManager = await D(for: album, albumManager: albumManager)
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
    func handleSelectedFiles(urls: [URL]) {
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



    func handleSelectedMedia(items: [PHPickerResult]) {
        Task {
            var allMedia: [CleartextMedia] = []

            for result in items {
                let provider = result.itemProvider
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
                }

                // Collect media instead of saving immediately
                let media = try await self.loadMediaAsync(result: result)
                allMedia.append(contentsOf: media)
            }
            
            // Use background import manager for all media at once
            guard let albumId = album?.id else {
                debugPrint("No album ID available")
                return
            }
            
            do {
                try await BackgroundMediaImportManager.shared.startImport(media: allMedia, albumId: albumId)
                EventTracking.trackMediaImported(count: items.count)
            } catch {
                debugPrint("Error starting import: \(error)")
            }
            
            lastImportedAssets = items
            try await checkForLibraryPermissionsAndContinue()

            await gridViewModel.enumerateMedia()
        }
    }

    func handleSelectedPhotosPickerItems(items: [PhotosPickerItem]) async {
        var allMedia: [CleartextMedia] = []
        var phPickerResults: [PHPickerResult] = []
        
        for item in items {
            // Track statistics - check supported types directly on PhotosPickerItem
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
            } else if item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) {
                UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
            }
            
            // Convert PhotosPickerItem to media
            do {
                // Check if it's a live photo by trying to load it
                if let livePhoto = try await item.loadTransferable(type: PHLivePhoto.self) {
                    // Handle live photo
                    let resources = PHAssetResource.assetResources(for: livePhoto)
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
                    allMedia.append(contentsOf: cleartextMediaArray)
                } else if let data = try await item.loadTransferable(type: Data.self) {
                    // Handle regular photo or video
                    let isVideo = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
                    let fileName = NSUUID().uuidString + (isVideo ? ".mov" : ".jpeg")
                    let destinationURL = URL.tempMediaDirectory.appendingPathComponent(fileName)
                    
                    try data.write(to: destinationURL)
                    let media = CleartextMedia(
                        source: destinationURL,
                        mediaType: isVideo ? .video : .photo,
                        id: UUID().uuidString
                    )
                    allMedia.append(media)
                }
            } catch {
                debugPrint("Error processing PhotosPickerItem: \(error)")
            }
        }
        
        // Use background import manager for all media at once
        guard let albumId = album?.id else {
            debugPrint("No album ID available")
            return
        }
        
        do {
            try await BackgroundMediaImportManager.shared.startImport(media: allMedia, albumId: albumId)
            EventTracking.trackMediaImported(count: items.count)
        } catch {
            debugPrint("Error starting import: \(error)")
        }
        
        // For photo library deletion permission check
        // Note: PhotosPickerItem doesn't provide asset identifiers for deletion
        await gridViewModel.enumerateMedia()
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

    func deleteSelectedMedia() {
        Task {
            var completedItems: [InteractableMedia<EncryptedMedia>] = []
            for media in selectedMedia {
                do {
                    try await fileManager.delete(media: media)
                    completedItems.append(media)
                } catch {
                    printDebug("Error deleting media: \(error)")
                }

            }
            selectedMedia.removeAll()

            await MainActor.run {
                gridViewModel.removeMedia(items: completedItems)
                isSelectingMedia = false
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
}

struct AlbumDetailView<D: FileAccess>: View {
    @State var isShowingMoveAlbumModal = false

    @StateObject var viewModel: AlbumDetailViewModel<D>
    @Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject var appModalStateModel: AppModalStateModel

    func popLastView() {
        presentationMode.wrappedValue.dismiss()
    }



    var body: some View {


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
            
            // Global import progress
            GlobalImportProgressView()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            
            if viewModel.isSelectingMedia {
                selectionTray
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
                if #available(iOS 17.0, *) {
                    // Use the modern embedded picker with continuous selection
                    NavigationStack {
                        VStack(spacing: 0) {
                            HStack {
                                Button("Cancel") {
                                    viewModel.selectedPhotoPickerItems.removeAll()
                                    viewModel.showPhotoPicker = nil
                                }
                                .padding()
                                
                                Spacer()
                                
                                VStack(spacing: 4) {
                                    Text("Select Photos")
                                        .font(.headline)
                                    if !viewModel.selectedPhotoPickerItems.isEmpty {
                                        Text("\(viewModel.selectedPhotoPickerItems.count) selected")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                Button("Add") {
                                    Task {
                                        await viewModel.handleSelectedPhotosPickerItems(items: viewModel.selectedPhotoPickerItems)
                                        viewModel.selectedPhotoPickerItems.removeAll()
                                        viewModel.showPhotoPicker = nil
                                    }
                                }
                                .disabled(viewModel.selectedPhotoPickerItems.isEmpty)
                                .fontWeight(.semibold)
                                .padding()
                            }
                            .background(Color(UIColor.systemBackground))
                            .overlay(
                                Divider(),
                                alignment: .bottom
                            )
                            
                            PhotosPicker(
                                selection: $viewModel.selectedPhotoPickerItems,
                                maxSelectionCount: nil,
                                selectionBehavior: .continuousAndOrdered,
                                matching: .any(of: [.images, .videos, .livePhotos]),
                                photoLibrary: .shared()
                            ) {
                                EmptyView()
                            }
                            .photosPickerStyle(.inline)
                            .photosPickerDisabledCapabilities([.selectionActions])
                            .photosPickerAccessoryVisibility(.automatic, edges: .bottom)
                            .ignoresSafeArea(.all, edges: .bottom)
                        }
                        .navigationBarHidden(true)
                    }
                    .interactiveDismissDisabled(!viewModel.selectedPhotoPickerItems.isEmpty)
                } else {
                    // Fallback to PHPickerViewController for older iOS versions
                    PhotoPicker(selectedItems: { results in
                        viewModel.handleSelectedMedia(items: results)
                    }, filter: .any(of: [.images, .videos, .livePhotos]))
                    .ignoresSafeArea(.all)
                }
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
                viewModel.showPhotoPicker = .photoLibrary
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
                        .becomeFirstResponder()
                        .fontType(.pt24, weight: .bold)
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
                viewModel.showPhotoPicker = .photoLibrary
            }

            Button(L10n.importFromFiles) {
                viewModel.showPhotoPicker = .files
            }

            //            Button {
            //                if viewModel.purchasedPermissions.hasEntitlement == false {
            //                    viewModel.isShowingPurchaseSheet = true
            //                    viewModel.afterPurchaseAction = {
            //                        viewModel.alertType = .hideAlbum
            //                    }
            //                } else if viewModel.isAlbumHidden {
            //                    viewModel.isAlbumHidden = false
            //                } else {
            //                    viewModel.alertType = .hideAlbum
            //                }
            //            } label: {
            //                HStack {
            //                    Text(L10n.AlbumDetailView.hideAlbumMenuItem)
            //                    Spacer()
            //                    if viewModel.isAlbumHidden {
            //                        Image(systemName: "checkmark")
            //                    }
            //                }
            //            }
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
