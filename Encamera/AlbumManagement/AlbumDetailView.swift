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
    @Published var cancelImport = false
    @MainActor
    @Published var isImporting = false
    @MainActor
    @Published var importProgress: Double = 0.0
    @MainActor
    @Published var totalImportCount: Int = 0
    @MainActor
    @Published var startedImportCount: Int = 0 {
        didSet {
            debugPrint("startedImportCount: \(startedImportCount)")
        }
    }

    private var currentTask: Task<Void, Error>?

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

    func cancelImporting() {
        currentTask?.cancel()
        cancelImport = true
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
        currentTask = Task {
            isImporting = true
            totalImportCount = urls.count
            for url in urls {
                if cancelImport {
                    isImporting = false
                    cancelImport = false
                    return
                }
                do {
                    try await saveCleartextMedia(mediaArray: [CleartextMedia(source: .url(url), generateID: true)])
                } catch {
                    debugPrint("Error saving media: \(error)")
                }
            }
            EventTracking.trackFilesImported(count: urls.count)
            isImporting = false
            await gridViewModel.enumerateMedia()
        }
    }

    private func loadAndSaveMediaAsync(result: PHPickerResult) async throws {
        // Identify whether the item is a video or an image
        let isLivePhoto = result.itemProvider.canLoadObject(ofClass: PHLivePhoto.self)
        Task { @MainActor in
            self.startedImportCount += 1
        }
        if isLivePhoto {
            try await handleLivePhoto(result: result)
        } else {
            try await handleMedia(result: result)
        }
    }

    private func handleMedia(result: PHPickerResult) async throws {
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
            return
        }

        try await saveCleartextMedia(mediaArray: [CleartextMedia(source: url, mediaType: isVideo ? .video : .photo, id: UUID().uuidString)])
    }


    private func saveCleartextMedia(mediaArray: [CleartextMedia]) async throws {
        let media = try InteractableMedia(underlyingMedia: mediaArray)
        let savedMedia = try await fileManager.save(media: media) { progress in
            Task { @MainActor in
                self.importProgress = progress
            }
        }
        await MainActor.run {
            self.importProgress = 0.0
        }
    }

    private func handleLivePhoto(result: PHPickerResult) async throws {

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

        try await saveCleartextMedia(mediaArray: cleartextMediaArray)
    }



    func handleSelectedMedia(items: [PHPickerResult]) {
        currentTask = Task {
            totalImportCount = items.count
            isImporting = true

            for result in items {
                if cancelImport {
                    isImporting = false
                    cancelImport = false
                    return
                }

                let provider = result.itemProvider
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
                }

                try await self.loadAndSaveMediaAsync(result: result)
            }
            lastImportedAssets = items
            try await checkForLibraryPermissionsAndContinue()

            EventTracking.trackMediaImported(count: items.count)

            isImporting = false
            await gridViewModel.enumerateMedia()
        }
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

    private var cancelButton: some View {
        Button {
            viewModel.cancelImporting()
        } label: {
            Image(systemName: "x.circle.fill")
        }
        .pad(.pt8, edge: .trailing)
    }

    var body: some View {


        VStack(spacing: 0) {
            Group {
                GalleryGridView(viewModel: viewModel.gridViewModel) {
                    VStack {
                        importProgressIndicator
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
                PhotoPicker(selectedItems: { results in
                    viewModel.handleSelectedMedia(items: results)
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

    var importProgressIndicator: some View {
        Group {
            if viewModel.cancelImport == false {
                HStack {
                    if viewModel.importProgress > 0 {
                        ProgressView(value: viewModel.importProgress, total: 1.0) {
                            Text("\(L10n.encrypting) \(viewModel.startedImportCount)/\(viewModel.totalImportCount)")
                                .fontType(.pt14)
                        }
                        .pad(.pt8, edge: [.trailing, .leading])
                        cancelButton

                    } else if viewModel.isImporting {
                        HStack {
                            ProgressView(value: 0.5, total: 1.0) {
                            }.progressViewStyle(.circular)
                                .pad(.pt8, edge: [.trailing, .leading])
                            Text("\(L10n.importingPleaseWait) \(viewModel.startedImportCount)/\(viewModel.totalImportCount)")
                                .fontType(.pt14)
                            Spacer()

                        }
                        cancelButton
                    }
                }
            }
        }
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
        .frame(maxWidth: .infinity)
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
