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
    @Published var importProgress: Double = 0.0
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

        #if targetEnvironment(simulator)
        self.fileAccess = DemoFileEnumerator()
        #else
        self.fileAccess = fileAccess
        #endif
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
        guard let album = album else { return }
        await fileAccess.configure(for: album, albumManager: albumManager)
        let enumerated: [EncryptedMedia] = await fileAccess.enumerateMedia()
        media = enumerated
        firstImage = enumerated.first
        enumerateiCloudUndownloaded()
    }

    func blurItemAt(index: Int) -> Bool {
        return purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: Double(media.count - index))) == false
    }

    func handleSelectedMedia(items: [PHPickerResult]) {
        Task {
            await withThrowingTaskGroup(of: Void.self) { group in
                for result in items {
                    group.addTask {
                        try await self.loadAndSaveMediaAsync(result: result)
                    }
                }
            }
            await enumerateMedia()
        }
    }

    private func loadAndSaveMediaAsync(result: PHPickerResult) async throws {
        let url = try await withCheckedThrowingContinuation { continuation in
            let prog = result.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.item") { url, error in
                guard let url = url else {
                    // Handle error or early exit if URL is not available
                    print("Error loading file representation: \(String(describing: error))")
                    fatalError()
                    return
                }
                let destinationURL = URL.tempMediaDirectory
                    .appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: url, to: destinationURL)
                    debugPrint("File copied to: \(destinationURL)")
                    continuation.resume(returning: destinationURL)
                } catch {
                    print("Error copying file: \(error)")
                    continuation.resume(throwing: error)
                }
            }
            
        }

        let media = CleartextMedia(source: url)
        try await fileAccess.save(media: media) { progress in
            self.importProgress = progress
        }
        self.importProgress = 0.0
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


    var body: some View {
        VStack {
            content
            if viewModel.importProgress > 0 {
                ProgressView(value: viewModel.importProgress, total: 1.0)
            }
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

                        } else if viewModel.album != nil {
                            emptyState
                        }
                    }
                    .padding(spacing)
                    .onChange(of: viewModel.showCamera) { oldValue, newValue in
                        EventTracking.trackOpenedCameraFromAlbumEmptyState()
                        viewModel.albumManager.currentAlbum = viewModel.album
                    }

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
            }
        }
        .sheet(isPresented: $viewModel.showPhotoPicker, content: {
            PhotoPicker(selectedItems: { results in
                viewModel.handleSelectedMedia(items: results)
            }, filter: .any(of: [.images, .videos]))
        })
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.selectAnOption.uppercased())
                .fontType(.pt14, weight: .bold)
                .foregroundColor(.white)
                .opacity(0.40)
              Button(action: {
                  viewModel.showCamera = true
              }, label: {
                  AlbumActionComponent(mainTitle: "Create a new memory", subTitle: "Open your camera and take a pic", actionTitle: "Take a picture", imageName: "Album-Camera")
              })
              Button(action: {
                  viewModel.showPhotoPicker = true
              }, label: {
                  AlbumActionComponent(mainTitle: "Secure your pics", subTitle: "Import pictures from your camera roll", actionTitle: "Import Pictures", imageName: "Premium-Albums")
              })
        }
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
