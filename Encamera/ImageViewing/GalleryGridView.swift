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

@MainActor
class GalleryGridViewModel<T: MediaDescribing, D: FileAccess>: ObservableObject {

    var album: Album?
    var albumManager: AlbumManaging
    var purchasedPermissions: PurchasedPermissionManaging
    @MainActor
    @Published var media: [EncryptedMedia] = []
    @Published var showCamera: Bool = false
    @Published var showPhotoPicker: Bool = false
    @Published var firstImage: EncryptedMedia?
    @Published var showingCarousel = false
    @Published var downloadPendingMediaCount: Int = 0
    @Published var downloadInProgress = false
    @Published var blurImages = false
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
    @Published var carouselTarget: EncryptedMedia? {
        didSet {
            if carouselTarget == nil {
                showingCarousel = false
            } else {
                showingCarousel = true
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()
    var fileAccess: FileAccess
    @MainActor
    @Published var showEmptyView: Bool = false

    init(album: Album?,
         albumManager: AlbumManaging,
         blurImages: Bool = false,
         showingCarousel: Bool = false,
         downloadPendingMediaCount: Int = 0,
         carouselTarget: EncryptedMedia? = nil,
         fileAccess: FileAccess,
         purchasedPermissions: PurchasedPermissionManaging = AppPurchasedPermissionUtils()
    ) {
        self.blurImages = blurImages
        self.albumManager = albumManager
        self.album = album
        self.showingCarousel = showingCarousel
        self.downloadPendingMediaCount = downloadPendingMediaCount
        self.carouselTarget = carouselTarget

//#if targetEnvironment(simulator)
//        self.fileAccess = DemoFileEnumerator()
//#else
        self.fileAccess = fileAccess
//#endif
        self.purchasedPermissions = purchasedPermissions
        FileOperationBus.shared.operations.sink { operation in
            Task {
                await self.enumerateMedia()
            }
        }.store(in: &cancellables)
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
            .store(in: &cancellables)
    }

    func enumerateiCloudUndownloaded() {
        downloadPendingMediaCount = media.filter({$0.needsDownload == true}).count
        if downloadPendingMediaCount == 0 {
            downloadInProgress = false
            cancellables.forEach({$0.cancel()})
        }
    }

    func cleanUp() {
        cancellables.forEach({$0.cancel()})
        downloadInProgress = false
    }

    func enumerateMedia() async {
        guard let album = album else {
            debugPrint("No album")
            return
        }
        await fileAccess.configure(for: album, albumManager: albumManager)
        let enumerated: [EncryptedMedia] = await fileAccess.enumerateMedia()
        debugPrint("enumerated: \(enumerated)")
        media = enumerated
        firstImage = enumerated.first
        enumerateiCloudUndownloaded()
        let empty = enumerated.isEmpty
        showEmptyView = empty
    }

    func blurItemAt(index: Int) -> Bool {
        return purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: Double(media.count - index))) == false
    }

    func handleSelectedMedia(items: [PHPickerResult]) {
        Task {
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
            EventTracking.trackMediaImported(count: items.count)

            isImporting = false
            await enumerateMedia()
        }
    }

    private func loadAndSaveMediaAsync(result: PHPickerResult) async throws {

        // Identify whether the item is a video or an image
        let isVideo = result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let preferredType = isVideo ? UTType.movie.identifier : UTType.image.identifier
        let url: URL? = try await withCheckedThrowingContinuation { continuation in
            // Ensure we're on the main thread when modifying UI-bound properties
            Task { @MainActor in
                self.startedImportCount += 1
            }

            result.itemProvider.loadFileRepresentation(forTypeIdentifier: preferredType) { url, error in
                guard let url = url else {
                    debugPrint("Error loading file representation: \(String(describing: error))")
                    continuation.resume(returning: nil)
                    return
                }
                // Generate a unique file name to prevent overwriting existing files
                let fileName = NSUUID().uuidString + (isVideo ? ".mov" : ".jpeg")
                let destinationURL = URL.tempMediaDirectory
                    .appendingPathComponent(fileName)
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
        let media = CleartextMedia(source: url) // Ensure CleartextMedia can handle URLs for both images and videos
        debugPrint("Will save media: \(media)")
        let savedMedia = try await fileAccess.save(media: media) { progress in // Ensure fileAccess and its save method are correctly implemented
            debugPrint("Progress: \(progress)")
            Task { @MainActor in
                self.importProgress = progress
            }
        }
        debugPrint("Media saved: \(savedMedia?.url?.absoluteString ?? "nil")")
        await MainActor.run {
            self.importProgress = 0.0 // Reset or update progress as necessary
        }
    }


}

private enum Constants {
    static let hideButtonWidth = 100.0
    static let numberOfImagesWide = 2.0
    static let blurRadius = AppConstants.blockingBlurRadius
    static let buttonPadding = 7.0
    static let buttonCornerRadius = 10.0
}

struct GalleryGridView<Content: View, T: MediaDescribing, D: FileAccess>: View {

    @ObservedObject var viewModel: GalleryGridViewModel<T, D>
    var content: Content

    init(viewModel: GalleryGridViewModel<T, D>, @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.viewModel = viewModel
        self.content = content()
    }

    private var cancelButton: some View {
        Button {
            viewModel.cancelImport = true
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
                            Text("\(L10n.downloadingFromICloud) \(viewModel.startedImportCount)/\(viewModel.totalImportCount)")
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
        .onChange(of: viewModel.showCamera) { oldValue, newValue in
            EventTracking.trackOpenedCameraFromAlbumEmptyState()
            viewModel.albumManager.currentAlbum = viewModel.album
        }
        .fullScreenCover(isPresented: $viewModel.showCamera, content: {

            if viewModel.album != nil {
                CameraView(cameraModel: .init(
                    albumManager: viewModel.albumManager,
                    cameraService: CameraConfigurationService(model: CameraConfigurationServiceModel()),
                    fileAccess: viewModel.fileAccess,
                    purchaseManager: viewModel.purchasedPermissions,
                    closeButtonTapped: { _ in
                        viewModel.showCamera = false
                        viewModel.albumManager.currentAlbum = viewModel.album
                        Task {
                            await viewModel.enumerateMedia()
                        }
                    }
                ), hasMediaToImport: .constant(false))
            }
        })
        .sheet(isPresented: $viewModel.showPhotoPicker, content: {
            PhotoPicker(selectedItems: { results in
                viewModel.handleSelectedMedia(items: results)
            }, filter: .any(of: [.images, .videos]))
            .ignoresSafeArea(.all)
        })
    }

    private var mainGridView: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .local)
            let outerMargin = 9.0
            let spacing = 9.0
            let largeSide = frame.width - spacing * Constants.numberOfImagesWide

            let side = ((frame.width - outerMargin) / Constants.numberOfImagesWide) - spacing
            let gridItems = [
                GridItem(.fixed(side), spacing: spacing),
                GridItem(.fixed(side), spacing: spacing),
            ]
            ZStack(alignment: .center) {
                ScrollView {
                    HStack {
                        if viewModel.downloadPendingMediaCount > 0 {
                            downloadFromiCloudButton
                        }
                    }
                    .padding(.bottom)
                    if let first = viewModel.firstImage {
                        let remainingImages = viewModel.media[1..<viewModel.media.count]
                        imageForItem(mediaItem: first, width: largeSide, height: largeSide, index: 0)
                        LazyVGrid(columns: gridItems, spacing: spacing) {
                            ForEach(Array(remainingImages.enumerated()), id: \.element) { index, mediaItem in
                                imageForItem(mediaItem: mediaItem, width: side, height: side, index: index)
                            }
                            Spacer().frame(height: getSafeAreaBottom())
                        }
                        .blur(radius: viewModel.blurImages ? Constants.buttonCornerRadius : 0.0)
                        .animation(.easeIn, value: viewModel.blurImages)
                        .frame(width: largeSide)

                    }
                }
                .padding(spacing)
                NavigationLink(isActive: $viewModel.showingCarousel) {
                    if let carouselTarget = viewModel.carouselTarget, viewModel.showingCarousel == true {

                        GalleryHorizontalScrollView(
                            viewModel: .init(
                                media: viewModel.media,
                                selectedMedia: carouselTarget,
                                fileAccess: viewModel.fileAccess,
                                purchasedPermissions: viewModel.purchasedPermissions
                            ))
                    }
                } label: {
                    EmptyView()
                }

            }
            .task {
                await viewModel.enumerateMedia()
            }
            .onAppear {
                AskForReviewUtil.askForReviewIfNeeded()
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
                viewModel.showPhotoPicker = true
            },
                                secondaryButtonTitle: L10n.AlbumDetailView.openCamera,
                                secondaryButtonAction: {
                viewModel.showCamera = true
            })
            Spacer().frame(height: 8)
        }.padding()
    }

    private func imageForItem(mediaItem: EncryptedMedia, width: CGFloat, height: CGFloat, index: Int) -> some View {

        AsyncEncryptedImage(viewModel: .init(targetMedia: mediaItem, loader: viewModel.fileAccess),
                            placeholder: ProgressView(), isInSelectionMode: .constant(false), isSelected: .constant(false))
        .id(mediaItem.gridID)
        .frame(width: width, height: height)
        .onTapGesture {
            viewModel.carouselTarget = mediaItem
        }
        .blur(radius: viewModel.blurItemAt(index: index) ? Constants.blurRadius : 0.0)
        .galleryClipped()

    }

    private var downloadFromiCloudButton: some View {
        Button {
            viewModel.startiCloudDownload()
        } label: {

            HStack {
                if viewModel.downloadInProgress {
                    ProgressView()
                        .tint(Color.foregroundPrimary)
                    Spacer()
                        .frame(width: 5)
                } else {
                    Text("\(viewModel.downloadPendingMediaCount)")
                        .fontType(.pt18)
                }
                Image(systemName: "icloud.and.arrow.down")
            }
        }
        .padding(Constants.buttonPadding)
        .background(Color.foregroundSecondary)
        .cornerRadius(Constants.buttonCornerRadius)

    }
}

#Preview {
    GalleryGridView<EmptyView, EncryptedMedia, DemoFileEnumerator>(viewModel: .init(album: Album(name: "Chee", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey()), albumManager: DemoAlbumManager(), fileAccess: DemoFileEnumerator()))
}
