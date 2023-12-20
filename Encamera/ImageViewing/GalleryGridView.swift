//
//  GalleryView.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI
import Combine
import EncameraCore

@MainActor
class GalleryGridViewModel<T: MediaDescribing>: ObservableObject {

    var privateKey: PrivateKey
    var album: Album?
    var albumManager: AlbumManaging
    var purchasedPermissions: PurchasedPermissionManaging
    @MainActor
    @Published var media: [EncryptedMedia] = []
    @Published var showCamera: Bool = false
    @Published var firstImage: EncryptedMedia?
    @Published var showingCarousel = false
    @Published var downloadPendingMediaCount: Int = 0
    @Published var downloadInProgress = false
    @Published var blurImages = false
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
    var fileAccess: FileAccess = DiskFileAccess()

    init(privateKey: PrivateKey,
         album: Album?,
         albumManager: AlbumManaging,
         blurImages: Bool = false,
         showingCarousel: Bool = false,
         downloadPendingMediaCount: Int = 0,
         carouselTarget: EncryptedMedia? = nil,
         fileAccess: FileAccess = DiskFileAccess(),
         purchasedPermissions: PurchasedPermissionManaging = AppPurchasedPermissionUtils()
    ) {
        self.blurImages = blurImages
        self.albumManager = albumManager
        self.privateKey = privateKey
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
        await fileAccess.configure(for: album, with: privateKey, albumManager: albumManager)
        let enumerated: [EncryptedMedia] = await fileAccess.enumerateMedia()
        media = enumerated
        firstImage = enumerated.first
        enumerateiCloudUndownloaded()
    }

    func blurItemAt(index: Int) -> Bool {
        return purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: Double(media.count - index))) == false
    }
}

private enum Constants {
    static let hideButtonWidth = 100.0
    static let numberOfImagesWide = 2.0
    static let blurRadius = AppConstants.blockingBlurRadius
    static let buttonPadding = 7.0
    static let buttonCornerRadius = 10.0
}

struct GalleryGridView<Content: View, T: MediaDescribing>: View {

    @ObservedObject var viewModel: GalleryGridViewModel<T>
    var content: Content

    init(viewModel: GalleryGridViewModel<T>, @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.viewModel = viewModel
        self.content = content()
    }


    var body: some View {
        VStack {
            content
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

                    if let album = viewModel.album {
                        CameraView(cameraModel: .init(
                            privateKey: album.key,
                            albumManager: viewModel.albumManager,
                            cameraService: CameraConfigurationService(model: CameraConfigurationServiceModel()),
                            fileAccess: viewModel.fileAccess,
                            purchaseManager: viewModel.purchasedPermissions
                        ), hasMediaToImport: .constant(false)) {
                            viewModel.showCamera = false
                            viewModel.albumManager.currentAlbum = viewModel.album
                            Task {
                                await viewModel.enumerateMedia()
                            }
                        }
                    }
                })
            }
        }
    }
    
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.addPhotosToThisAlbum)
                .fontType(.pt14, weight: .bold)
                .foregroundColor(.white)
                .opacity(0.40)
          VStack(alignment: .leading, spacing: 16) {

              OptionItemView(title: L10n.takeAPhoto, description: L10n.useCameraToTakePhotos, isAvailable: true, unavailableReason: nil, image: Image("Onboarding-Permissions-Camera"), isSelected: $viewModel.showCamera)

          }
        }
        .padding()
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

    NavigationView {
        GalleryGridView(viewModel: GalleryGridViewModel<EncryptedMedia>(privateKey: DemoPrivateKey.dummyKey(), album: Album(name: "Name", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey()), albumManager: DemoAlbumManager(), blurImages: false)) {
            List {
            }
            .frame(height: 300)
            .fontType(.pt18)
            .scrollContentBackgroundColor(Color.random
            )

        }
    }
}
