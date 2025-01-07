//
//  GalleryView.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI
import Combine
import EncameraCore
import UniformTypeIdentifiers
import PhotosUI

enum ImportError: Error {
    case mismatchedType
}

enum ImportSource {
    case photoLibrary
    case files
}

@MainActor
class GalleryGridViewModel<D: FileAccess>: ObservableObject {

    var album: Album?
    var albumManager: AlbumManaging
    var purchasedPermissions: PurchasedPermissionManaging

    @MainActor
    @Published var media: [InteractableMedia<EncryptedMedia>] = []
    @Published var currentModal: AppModal?

    var showFullScreenCover: Binding<Bool> {
        Binding {
            self.currentModal != nil
        } set: { newValue in
            if newValue == false {
                self.currentModal = nil
            }
        }
    }

    @Published var showPhotoPicker: ImportSource? = nil
    @Published var showPhotoAccessAlert: Bool = false
    @Published var showingCarousel = false
    @Published var downloadPendingMediaCount: Int = 0
    @Published var downloadInProgress = false
    @Published var blurImages = false
    @Published var isSelectingMedia = false
    @Published var selectedMedia: Set<InteractableMedia<EncryptedMedia>> = Set()
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
    @Published var showPurchaseScreen: Bool = false
    @Published var lastImportedAssets: [PHPickerResult] = []
    @Published var showNoLicenseDeletionWarning: Bool = false
    var agreedToDeleteWithNoLicense: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var iCloudCancellables = Set<AnyCancellable>()
    private var currentTask: Task<Void, Error>?
    var fileAccess: D
    @MainActor
    @Published var showEmptyView: Bool = false

    var cameraModel: CameraModel
    
    init(album: Album?,
         albumManager: AlbumManaging,
         blurImages: Bool = false,
         showingCarousel: Bool = false,
         downloadPendingMediaCount: Int = 0,
         fileAccess: D
    ) {
        self.purchasedPermissions = AppPurchasedPermissionUtils()
        self.blurImages = blurImages
        self.albumManager = albumManager
        self.album = album
        self.showingCarousel = showingCarousel
        self.downloadPendingMediaCount = downloadPendingMediaCount
        //#if targetEnvironment(simulator)
        //        self.fileAccess = DemoFileEnumerator()
        //#else
        self.fileAccess = fileAccess
        //#endif
        self.cameraModel = .init(
            albumManager: albumManager,
            cameraService: CameraConfigurationService(model: CameraConfigurationServiceModel()),
            fileAccess: fileAccess,
            purchaseManager: purchasedPermissions
        )
        FileOperationBus.shared.operations.sink { operation in
            #warning("This is a temporary fix, make it more graceful and refactor FileOperationBus")
            guard self.isSelectingMedia == false else {
                return
            }

            Task {
                await self.enumerateMedia()
            }
        }.store(in: &cancellables)
        self.$isSelectingMedia.sink { value in
            if value == false {
                self.selectedMedia = []
            }
        }.store(in: &cancellables)

    }

    func checkForLibraryPermissionsAndContinue() async throws {
        let status = PHPhotoLibrary.authorizationStatus()

        if status == .notDetermined {
            showPhotoAccessAlert = true
        } else if status == .authorized || status == .limited {
            try await deleteMediaFromPhotoLibrary(result: lastImportedAssets)
        }
    }

    func cancelImporting() {
        currentTask?.cancel()
        cancelImport = true
    }

    func requestPhotoLibraryPermission() async {
        if agreedToDeleteWithNoLicense == false && purchasedPermissions.hasEntitlement() == false {
            showNoLicenseDeletionWarning = true
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

    func startiCloudDownload() {
        guard let album else { return }
        let directory = albumManager.storageModel(for: album)
        if let iCloudStorageDirectory = directory as? iCloudStorageModel {
            iCloudStorageDirectory.triggerDownloadOfAllFilesFromiCloud()
        } else {
            return
        }
        downloadInProgress = true
        Timer.publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .receive(on: DispatchQueue.main)
            .sink { out in
                Task {
                    await self.enumerateMedia()
                }
            }
            .store(in: &iCloudCancellables)
    }

    func enumerateiCloudUndownloaded() {
        downloadPendingMediaCount = media.filter({$0.needsDownload == true}).count
        if downloadPendingMediaCount == 0 {
            downloadInProgress = false
            iCloudCancellables.forEach({$0.cancel()})
        }
    }

    func cleanUp() {
        iCloudCancellables.forEach({$0.cancel()})
        downloadInProgress = false
    }

    func enumerateMedia() async {
        guard let album = album else {
            debugPrint("No album")
            return
        }
        await fileAccess.configure(for: album, albumManager: albumManager)
        let enumerated: [InteractableMedia<EncryptedMedia>] = await fileAccess.enumerateMedia()
        media = enumerated
        enumerateiCloudUndownloaded()
        showEmptyView = enumerated.isEmpty
    }

    func blurItemAt(index: Int) -> Bool {
        return purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: Double(media.count - index))) == false
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
            await enumerateMedia()
        }
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
            await enumerateMedia()
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

    private func deleteMediaFromPhotoLibrary(result: [PHPickerResult]) async throws {

        let assetIdentifier = result.compactMap({$0.assetIdentifier})

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifier, options: nil)

        if assets.count > 0 {
            do {
                try await PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets(assets)
                })
                debugPrint("Media successfully deleted from Photo Library")

            } catch {
                debugPrint("Failed to delete media: \(error)")
            }
        } else {
            debugPrint("No assets found to delete")
        }
    }

    private func saveCleartextMedia(mediaArray: [CleartextMedia]) async throws {
        let media = try InteractableMedia(underlyingMedia: mediaArray)
        let savedMedia = try await fileAccess.save(media: media) { progress in
            Task { @MainActor in
                self.importProgress = progress
            }
        }
        debugPrint("Media saved: \(savedMedia?.photoURL?.absoluteString ?? "nil")")
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

    func removeMedia(items: [InteractableMedia<EncryptedMedia>]) {
        withAnimation(.easeInOut(duration: 0.4)) {
            for item in items {
                if let index = self.media.firstIndex(of: item) {
                    media.remove(at: index)
                }
            }
            showEmptyView = media.isEmpty
        }
    }


}

private enum Constants {
    static let hideButtonWidth = 100.0

    static func numberOfImagesWide(for size: CGSize) -> Int {
            let device = UIDevice.current
            let width = size.width

            switch device.userInterfaceIdiom {
            case .pad:
                return width > 800 ? 5 : 3  // iPads: 4 columns for wide screens, 3 for narrow screens
            case .phone:
                return width > 600 ? 3 : 2  // iPhones: 3 columns for wide screens, 2 for narrow screens
            default:
                return 2
            }
        }
    static let buttonPadding = 7.0
    static let buttonCornerRadius = 10.0
}

struct GalleryGridView<Content: View, D: FileAccess>: View {

    @ObservedObject var viewModel: GalleryGridViewModel<D>
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    var content: Content

    init(viewModel: GalleryGridViewModel<D>, @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.viewModel = viewModel
        self.content = content()
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
        VStack {

            content
            if viewModel.cancelImport == false {
                HStack {
                    if viewModel.importProgress > 0 {
                        ProgressView(value: viewModel.importProgress, total: 1.0) {
                            Text("\(L10n.encrypting) \(viewModel.startedImportCount)/\(viewModel.totalImportCount)")
                                .fontType(.pt14)
                        }                    .pad(.pt8, edge: [.trailing, .leading])
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
            if viewModel.showEmptyView {
                emptyState
            } else {
                mainGridView
            }

        }
        .onChange(of: viewModel.currentModal) { oldValue, newValue in
            if case .cameraView = newValue {
                EventTracking.trackOpenedCameraFromAlbumEmptyState()
                viewModel.albumManager.currentAlbum = viewModel.album
            }
        }
        .fullScreenCover(isPresented: viewModel.showFullScreenCover, content: {

            switch viewModel.currentModal {
            case .cameraView:
                if viewModel.album != nil {
                    CameraView(cameraModel: viewModel.cameraModel, hasMediaToImport: .constant(false), closeButtonTapped:  { _ in
                        viewModel.currentModal = nil
                        viewModel.albumManager.currentAlbum = viewModel.album
                        Task {
                            await viewModel.enumerateMedia()
                        }
                    })
                }
            case .galleryScrollView(context: let context):
                GalleryViewWrapper(viewModel: .init(media: context.media, initialMedia: context.targetMedia, fileAccess: viewModel.fileAccess, purchasedPermissions: viewModel.purchasedPermissions, purchaseButtonPressed: {
                    viewModel.currentModal = nil
                    viewModel.showPurchaseScreen = true
                }, reviewAlertActionPressed: { selection in
                    if selection == .no {
                        viewModel.currentModal = .feedbackView
                    }

                }))
                    .ignoresSafeArea(edges: [.top, .bottom, .leading, .trailing])
            case .feedbackView:
                FeedbackView()
            case nil:
                AnyView(EmptyView())
            }

        })
        .alert(isPresented: Binding<Bool>(
            get: { viewModel.showNoLicenseDeletionWarning || viewModel.showPhotoAccessAlert },
            set: { newValue in
                viewModel.showNoLicenseDeletionWarning = false
                viewModel.showPhotoAccessAlert = false
            }
        )) {
            if viewModel.showNoLicenseDeletionWarning {
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
            } else if viewModel.showPhotoAccessAlert {
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
            } else {
                // Fallback alert to prevent SwiftUI from complaining, though this shouldn't be shown
                return Alert(title: Text("Unknown Error"))
            }
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
    }

    private var mainGridView: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .local)
            let outerMargin = 9.0
            let spacing = 9.0
            let numberOfImages = Constants.numberOfImagesWide(for: frame.size)
            let side = ((frame.width - outerMargin) / Double(numberOfImages)) - spacing

            let gridItems = Array(repeating: GridItem(.fixed(side), spacing: spacing), count: numberOfImages)

            ZStack(alignment: .center) {
                ScrollView {
                    LazyVGrid(columns: gridItems, spacing: spacing) {
                        ForEach(Array(viewModel.media.enumerated()), id: \.element) { index, mediaItem in
                            imageForItem(mediaItem: mediaItem, width: side, height: side, index: index)
                        }
                        Spacer().frame(height: getSafeAreaBottom())
                    }
                    .blur(radius: viewModel.blurImages ? Constants.buttonCornerRadius : 0.0)
                    .animation(.easeIn, value: viewModel.blurImages)
                }
                .padding([.leading, .trailing], outerMargin)
            }
            .task {
                await viewModel.enumerateMedia()
            }
            .onDisappear {
                viewModel.cleanUp()
            }
            .scrollIndicators(.hidden)
            .navigationBarTitle("")
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
                viewModel.currentModal = .cameraView
            })
            Spacer().frame(height: 8)
        }.padding()
    }

    private func imageForItem(mediaItem: InteractableMedia<EncryptedMedia>, width: CGFloat, height: CGFloat, index: Int) -> some View {


            Group {
                let selectionBinding = Binding<Bool> {
                    viewModel.selectedMedia.contains(mediaItem)
                } set: { selected, _ in

                    if selected {
                        viewModel.selectedMedia.insert(mediaItem)
                    } else {
                        viewModel.selectedMedia.remove(mediaItem)
                    }
                }

                let blurBinding = Binding<Bool> {
                    viewModel.blurItemAt(index: index)
                } set: { _ in
                }

                AsyncEncryptedImage(
                    viewModel: .init(targetMedia: mediaItem, loader: viewModel.fileAccess),
                    placeholder: ProgressView(),
                    isInSelectionMode: $viewModel.isSelectingMedia,
                    isSelected: selectionBinding,
                    isBlurred: blurBinding
                )
                .id(mediaItem.gridID)
                .frame(width: width, height: height)
                .galleryClipped()
                .transition(.asymmetric(insertion: .scale, removal: .opacity.combined(with: .scale(scale: 0.7))))

            }.onTapGesture {
                viewModel.currentModal = AppModal.galleryScrollView(
                    context: GalleryScrollViewContext(
                        media: viewModel.media,
                        targetMedia: mediaItem))
            }

    }

}

//#Preview {
//    GalleryGridView<EmptyView, InteractableMedia<EncryptedMedia>, DemoFileEnumerator>(viewModel: .init(album: Album(name: "Chee", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey()), albumManager: DemoAlbumManager(), fileAccess: DemoFileEnumerator()))
//}
