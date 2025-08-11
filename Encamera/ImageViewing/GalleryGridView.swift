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

    @Published var showingCarousel = false
    @Published var downloadPendingMediaCount: Int = 0
    @Published var downloadInProgress = false
    @Published var blurImages = false
    @Published var isSelectingMedia = false
    @Published var selectedMedia: Set<InteractableMedia<EncryptedMedia>> = Set()
    @Published var noMediaShown: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var iCloudCancellables = Set<AnyCancellable>()
    var fileAccess: D
    @MainActor
    
    init(album: Album?,
         albumManager: AlbumManaging,
         blurImages: Bool = false,
         showingCarousel: Bool = false,
         downloadPendingMediaCount: Int = 0,
         fileAccess: D,
         purchasedPermissions: PurchasedPermissionManaging
    ) {
        self.purchasedPermissions = purchasedPermissions
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

        FileOperationBus.shared.operations.sink { operation in
            Task {
                await MainActor.run {
                    switch operation {
                    case .delete(let deletedMedia):
                        // Handle animated deletion
                        self.handleDeletedMedia(deletedMedia)
                        
                        // Clear selection if we're in selection mode
                        if self.isSelectingMedia {
                            self.isSelectingMedia = false
                            self.selectedMedia = []
                        }
                        
                    case .move(let movedMedia, let targetAlbum):
                        // Handle animated move (only if it's moving FROM current album)
                        if let currentAlbum = self.album, currentAlbum.id != targetAlbum.id {
                            self.handleMovedMedia(movedMedia)
                        }
                        
                        // Clear selection if we're in selection mode
                        if self.isSelectingMedia {
                            self.isSelectingMedia = false
                            self.selectedMedia = []
                        }
                        
                    case .create:
                        // For create operations, refresh the full list
                        Task {
                            // Add a small delay to ensure file operations have completed
                            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                            await self.enumerateMedia()
                        }
                    }
                }
            }
        }.store(in: &cancellables)
        self.$isSelectingMedia.sink { value in
            if value == false {
                self.selectedMedia = []
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

    @MainActor
    func enumerateMedia() async {
        guard let album = album else {
            debugPrint("No album")
            return
        }
        await fileAccess.configure(for: album, albumManager: albumManager)
        let enumerated: [InteractableMedia<EncryptedMedia>] = await fileAccess.enumerateMedia()
        media = enumerated
        enumerateiCloudUndownloaded()
        updateNoMediaState()
    }

    func blurItemAt(index: Int) -> Bool {
        return purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: Double(media.count - index))) == false
    }


    func removeMedia(items: [InteractableMedia<EncryptedMedia>]) {
        withAnimation(.easeInOut(duration: 0.4)) {
            for item in items {
                if let index = self.media.firstIndex(of: item) {
                    media.remove(at: index)
                }
            }
            updateNoMediaState()
        }
    }
    
    /// Handle animated deletion of specific media items based on EncryptedMedia
    @MainActor
    private func handleDeletedMedia(_ deletedEncryptedMedia: [EncryptedMedia]) {
        // Convert EncryptedMedia to InteractableMedia for comparison
        let itemsToRemove = media.filter { interactableMedia in
            deletedEncryptedMedia.contains { deletedEncrypted in
                // Compare by checking if any underlying media matches
                interactableMedia.underlyingMedia.contains { underlying in
                    underlying.id == deletedEncrypted.id
                }
            }
        }
        
        if !itemsToRemove.isEmpty {
            removeMedia(items: itemsToRemove)
        }
    }
    
    /// Handle animated move of specific media items based on EncryptedMedia  
    @MainActor
    private func handleMovedMedia(_ movedEncryptedMedia: [EncryptedMedia]) {
        // For moves, we treat it the same as deletion from the current album
        handleDeletedMedia(movedEncryptedMedia)
    }
    
    /// Update the noMediaShown state
    @MainActor
    private func updateNoMediaState() {
        noMediaShown = media.isEmpty
    }

}

private enum Constants {
    static let hideButtonWidth = 100.0
    static let buttonPadding = 7.0
    static let buttonCornerRadius = 10.0
    static let minColumns = 2
    static let maxColumns = 7
    
    static let defaultColumnCount: Int = {
        let device = UIDevice.current
        switch device.userInterfaceIdiom {
        case .pad:
            return 4
        case .phone:
            return 3
        default:
            return 3
        }
    }()

    static func numberOfImagesWide(for size: CGSize, zoomLevel: Int) -> Int {
        let device = UIDevice.current
        let width = size.width
        
        // Clamp the zoom level to valid range
        let clampedZoom = max(minColumns, min(maxColumns, zoomLevel))
        
        // For very small screens, limit max columns
        if width < 350 && clampedZoom > 4 {
            return 4
        }
        
        return clampedZoom
    }
}

struct GalleryGridView<Content: View, D: FileAccess>: View {

    @ObservedObject var viewModel: GalleryGridViewModel<D>
    @EnvironmentObject var appModalStateModel: AppModalStateModel

    @State private var zoomLevel: Int = UserDefaultUtils.integer(forKey: .gridZoomLevel) > 0 ? UserDefaultUtils.integer(forKey: .gridZoomLevel) : Constants.defaultColumnCount
    @State private var currentPinchScale: CGFloat = 1.0
    @State private var lastZoomLevel: Int = Constants.defaultColumnCount
    
    var content: Content

    init(viewModel: GalleryGridViewModel<D>, @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.viewModel = viewModel
        self.content = content()
    }

    var body: some View {
        VStack {

            content
            if !viewModel.noMediaShown {
                mainGridView
            }
        }

    }

    private var mainGridView: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .local)
            let outerMargin = 9.0
            let spacing = 9.0
            let numberOfImages = Constants.numberOfImagesWide(for: frame.size, zoomLevel: zoomLevel)
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
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            handlePinchGesture(scale: value)
                        }
                        .onEnded { _ in
                            lastZoomLevel = zoomLevel
                            currentPinchScale = 1.0
                            UserDefaultUtils.set(zoomLevel, forKey: .gridZoomLevel)
                        }
                )
                .contentMargins([.top, .bottom], outerMargin)
                .padding([.leading, .trailing], outerMargin)
            }
            .task {
                await viewModel.enumerateMedia()
            }
            .onDisappear {
                viewModel.cleanUp()
            }
            .scrollIndicators(.hidden)
            
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: zoomLevel)
        }
    }
    
    private func handlePinchGesture(scale: CGFloat) {
        let sensitivity: CGFloat = 0.5
        let scaleChange = (scale - currentPinchScale) * sensitivity
        
        if abs(scaleChange) > 0.1 {
            var newZoomLevel = lastZoomLevel
            
            if scaleChange > 0 {
                // Pinching out - decrease columns (zoom in)
                newZoomLevel = lastZoomLevel - 1
            } else {
                // Pinching in - increase columns (zoom out)
                newZoomLevel = lastZoomLevel + 1
            }
            
            let clampedLevel = max(Constants.minColumns, min(Constants.maxColumns, newZoomLevel))
            
            if clampedLevel != zoomLevel {
                zoomLevel = clampedLevel
                
                // Haptic feedback when zoom level changes
                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                impactFeedback.impactOccurred()
            }
            
            currentPinchScale = scale
        }
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
                appModalStateModel.currentModal = .galleryScrollView(
                    context: GalleryScrollViewContext(
                        sourceView: "GalleryGridView",
                        media: viewModel.media,
                        album: viewModel.album,
                        targetMedia: mediaItem))
            }

    }

}

//#Preview {
//    GalleryGridView<EmptyView, DemoFileEnumerator>(viewModel: .init(album: Album(name: "Chee", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey()), albumManager: DemoAlbumManager(), fileAccess: DemoFileEnumerator(), purchasedPermissions: DemoPurchasedPermissionManaging()))
//        .environmentObject(AppModalStateModel())
//}
