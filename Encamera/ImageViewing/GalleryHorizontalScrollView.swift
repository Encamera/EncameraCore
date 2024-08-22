//
//  GalleryHorizontalScrollView.swift
//  Encamera
//
//  Created by Alexander Freas on 16.08.22.
//

import SwiftUI
import Combine
import EncameraCore
import LinkPresentation
import UniformTypeIdentifiers



struct ViewOffsetKey: PreferenceKey {
    typealias Value = [UUID: CGFloat]

    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct TrackableView<Content: View>: View {
    let id: UUID
    let content: Content

    init(id: UUID, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            content
                .background(
                    Color.clear
                        .preference(key: ViewOffsetKey.self, value: [id: geometry.frame(in: .global).minX])
                )
        }
    }
}


@MainActor
class GalleryHorizontalScrollViewModel: NSObject, ObservableObject {

    @Published var media: [InteractableMedia<EncryptedMedia>] {
        didSet {
            updateMediaMap()
        }
    }

    func updateMediaMap() {
        let map = media.reduce(into: [:]) { result, media in
            result[media.id] = media
        }
        debugPrint("Media map updated: \(map)")
        mediaMap = map
    }
    var mediaMap: [String: InteractableMedia<EncryptedMedia>] = [:]
    @Published var selectedMedia: InteractableMedia<EncryptedMedia>?
    @Published var selectedMediaPreview: PreviewModel?
    @Published var initialMedia: InteractableMedia<EncryptedMedia>?
    @Published var showInfoSheet = false
    @Published var showPurchaseSheet = false
    @Published var isPlayingVideo = false
    @Published var isPlayingLivePhoto = false
    var lastProcessedValues = Set<CGFloat>()
    var purchasedPermissions: PurchasedPermissionManaging
    var showActionBar = true
    var fileAccess: FileAccess
    var currentSharingData: Any?
    private var cancellables = Set<AnyCancellable>()
    @Published var viewOffsets: [UUID: CGFloat] = [:]
    init(media: [InteractableMedia<EncryptedMedia>], initialMedia: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, showActionBar: Bool = true, purchasedPermissions: PurchasedPermissionManaging) {

        self.media = media
        self.fileAccess = fileAccess
        self.initialMedia = initialMedia
        self.showActionBar = showActionBar
        self.purchasedPermissions = purchasedPermissions
        super.init()
        updateMediaMap()
        // Debounce the viewOffsets updates
        $viewOffsets
            .sink { [weak self] values in
                guard let self = self else { return }
                let setValues = Set(values.values)
                self.lastProcessedValues = setValues
                for (id, minX) in values {
                    let viewFrame = minX
                    if viewFrame >= 0  {
                        let newSelection = self.mediaMap[id.uuidString]
                        if self.selectedMedia != newSelection {
                            self.selectedMedia = newSelection
                            loadThumbnailForActiveMedia()
                        }
                        debugPrint("Viewframe \(viewFrame) bounds: \(viewFrame + UIScreen.main.bounds.width) <= \(UIScreen.main.bounds.width)")

                    } else {
                        debugPrint("Not Viewframe \(viewFrame) bounds: \(viewFrame + UIScreen.main.bounds.width) <= \(UIScreen.main.bounds.width)")
                    }
                }
            }
            .store(in: &cancellables)
    }

    var selectedIndex: Int {
        guard let selectedMedia = selectedMedia else { return 0 }
        return media.firstIndex(of: selectedMedia) ?? 0
    }

    func deleteAction() {
        let targetIndex = selectedIndex
        guard let targetMedia = selectedMedia else {
            return
        }

        Task {


            do {
                try await fileAccess.delete(media: targetMedia)
                await MainActor.run {
                    _ = withAnimation {
                        media.remove(at: targetIndex)
                    }
                }
            } catch {
                debugPrint("Error deleting media", error)
            }
        }
    }
    var imageModels: [InteractableMedia<EncryptedMedia>.ID: ImageViewingViewModel] = [:]
    func modelForMedia(item: InteractableMedia<EncryptedMedia>) -> ImageViewingViewModel {
        if let model = imageModels[item.id] {
            return model
        } else {
            let model = ImageViewingViewModel(sourceMedia: item, fileAccess: fileAccess, delegate: self)
            imageModels[item.id] = model
            return model
        }

    }

    func loadThumbnailForActiveMedia() {
        guard let selectedMedia = selectedMedia else { return }
        Task {
            do {
                let thumbnail = try await fileAccess.loadMediaPreview(for: selectedMedia)
                selectedMediaPreview = thumbnail
            } catch {
                debugPrint("Error loading thumbnail", error)
            }
        }
    }
    func shareDecrypted() {
        guard let selectedMedia else { return }
        Task {
            let decrypted = try await self.fileAccess.loadMedia(media: selectedMedia) { _ in }

            switch selectedMedia.mediaType {
            case .stillPhoto:
                guard let data = decrypted.imageData, 
                        let image = UIImage(data: data)
                         else {
                    debugPrint("Error creating image provider")
                    return
                }
                let imageProvider = NSItemProvider(object: image)
                await MainActor.run {
                    shareSheet(data: [imageProvider])
                }

            case .livePhoto:
                guard let imageData = decrypted.imageData,
                      let videoURL = decrypted.videoURL,
                      let image = UIImage(data: imageData),
                      let videoProvider = NSItemProvider(contentsOf: videoURL) else {
                    debugPrint("Error creating image provider for Live Photo")
                    return
                }

                let imageProvider = NSItemProvider(object: image)

                await MainActor.run {
                    shareSheet(data: [imageProvider, videoProvider])
                }

            case .video:
                guard let videoURL = decrypted.videoURL, let videoProvider = NSItemProvider(contentsOf: videoURL) else {
                    debugPrint("Error creating video provider")
                    return
                }
                await MainActor.run {

                    shareSheet(data: [videoProvider])
                }
            }
        }
    }

    @MainActor
    func shareSheet(data: [NSItemProvider]) {
        self.currentSharingData = data

        let activityView = UIActivityViewController(activityItems: data, applicationActivities: nil)

        let allScenes = UIApplication.shared.connectedScenes
        let scene = allScenes.first { $0.activationState == .foregroundActive }

        if let windowScene = scene as? UIWindowScene {
            windowScene.keyWindow?.rootViewController?.present(activityView, animated: true, completion: nil)
        }
        EventTracking.trackMediaShared()
    }

    func canAccessPhoto(at index: Int) -> Bool {
        return purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: Double(media.count - index)))
    }

    func showPurchaseScreen() {
        showPurchaseSheet = true
    }
}

// Ensure that the GalleryHorizontalScrollViewModel conforms to UIActivityItemSource
extension GalleryHorizontalScrollViewModel: UIActivityItemSource {
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return "Encamera Media"
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return currentSharingData
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()

        if let selectedMediaPreview {
            guard let thumbnailData = selectedMediaPreview.thumbnailMedia.data else { return nil }
            let imageProvider = NSItemProvider(item: thumbnailData as NSData, typeIdentifier: UTType.png.identifier)
            metadata.imageProvider = imageProvider
            metadata.title = selectedMedia?.id
        }

        return metadata
    }
}

extension GalleryHorizontalScrollViewModel: MediaViewingDelegate {
    func didView(media: InteractableMedia<EncryptedMedia>) {
    }
}

struct GalleryHorizontalScrollView: View {


    typealias MagnificationGestureType = _EndedGesture<_ChangedGesture<MagnifyGesture>>
    typealias TapGestureType = _EndedGesture<TapGesture>
    typealias DragGestureType = _EndedGesture<_ChangedGesture<DragGesture>>

    @State var isScrollEnabled = true


    @StateObject var viewModel: GalleryHorizontalScrollViewModel
    @State var nextScrollViewXOffset: CGFloat = .zero
    @Namespace var scrollSpace
    @GestureState private var state = false
    @State var showingShareSheet = false
    @State var showingDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss
    var dragGestureRef = DragGesture(minimumDistance: 0)

    private let viewTitle: String = "GalleryView"

    var body: some View {
        VStack {

            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                VStack {
                    scrollView(frame: frame)
                }.confirmationDialog(L10n.deleteThisImage, isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {

                    Button(L10n.delete, role: .destructive) {
                        viewModel.deleteAction()
                    }
                }
                .confirmationDialog(L10n.shareThisImage, isPresented: $showingShareSheet) {
                    Button(L10n.shareDecrypted) {
                        viewModel.shareDecrypted()
                    }
                }
                .onChange(of: viewModel.isPlayingVideo) {
                    isScrollEnabled = !viewModel.isPlayingVideo
                }

            }
            if viewModel.showActionBar {
                actionBar
            }
        }
        .screenBlocked()


        .sheet(isPresented: $viewModel.showInfoSheet) {
            let content = Group {
                if let media = viewModel.selectedMedia {
                    PhotoInfoView(media: media, isPresented: $viewModel.showInfoSheet)
                } else {
                    EmptyView()
                }
            }
                .presentationDetents([.fraction(0.2)])
        }
        .background {
            if let preview = viewModel.selectedMediaPreview,
               let previewData = preview.thumbnailMedia.data,
               let image = UIImage(data: previewData) {
                Image(uiImage: image)
                    .resizable() // Ensure the image can be resized
                    .scaledToFill() // Scale the image to fill the entire view
                    .frame(maxWidth: .infinity, maxHeight: .infinity) // Make the image take up the full width and height
                    .blur(radius: 20) // Apply a blur effect to the image
                    .overlay(Color.black.opacity(0.3)) // Optional: Add a frost effect with an overlay
                    .clipped() // Clip the image to the bounds of the view
                    .ignoresSafeArea(.all)
                    .transition(.blurReplace)
            } else {
                EmptyView()
            }
        }
        .productStore(isPresented: $viewModel.showPurchaseSheet, fromViewName: viewTitle)
    }

    @State private var scrollViewWidth: CGFloat = 0 // Store the width of the ScrollView


    @ViewBuilder private func scrollView(frame: CGRect) -> some View {
        let gridItems = [
            GridItem(.fixed(frame.width), spacing: 0)
        ]

        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHGrid(rows: gridItems, spacing: 0) {
                    ForEach(Array(viewModel.media.enumerated()), id: \.element.id) { index, item in
                        ZStack {
                            let modalBinding = Binding<Bool> {
                                !viewModel.canAccessPhoto(at: index)
                            } set: { _ in }
                            TrackableView(id: UUID(uuidString: item.id)!) { // Wrap each item in TrackableView
                                viewingFor(item: item)
                                    .blur(radius: viewModel.canAccessPhoto(at: index) ? 0.0 : AppConstants.blockingBlurRadius)
                                    .photoLimitReachedModal(isPresented: modalBinding, addOverlay: false) {
                                        viewModel.showPurchaseScreen()
                                        EventTracking.trackPhotoLimitReachedScreenUpgradeTapped(from: "ImageScrollView")
                                    } onSecondaryButtonPressed: {
                                        EventTracking.trackPhotoLimitReachedScreenDismissed(from: "ImageScrollView")
                                        dismiss()
                                    }
                            }
                            .frame(width: frame.width, height: frame.height)
                            .id(item)
                            .clipped()
                        }
                    }
                    .onAppear {
                        scrollTo(media: viewModel.initialMedia, with: proxy, animated: false)
                    }

                }
                .scrollTargetLayout()
                .frame(maxHeight: .infinity)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: ViewOffsetKey.self, value: [UUID(): geometry.frame(in: .global).minX])
                            .onAppear {
                                guard scrollViewWidth == 0 else { return }
                                debugPrint("geometry appeared: \(geometry.size.width)")
                                scrollViewWidth = geometry.size.width // Capture the ScrollView width
                            }
                    }
                )
                .onPreferenceChange(ViewOffsetKey.self) { values in
                    debugPrint("View offsets changed: \(values)")
                    let setValues = Set(values.values)
                    guard setValues != viewModel.lastProcessedValues else {
                        return
                    }
                    print("setValues: \(setValues), lastProcessed: \(viewModel.lastProcessedValues)")
                    viewModel.viewOffsets = values
                }
            }
            .scrollDisabled(!isScrollEnabled)
            .scrollTargetBehavior(.viewAligned)
            .onChange(of: viewModel.selectedMedia) {
                viewModel.isPlayingVideo = false
            }

        }
        .scrollIndicators(.hidden)
    }
    @ViewBuilder private func viewingFor(item: InteractableMedia<EncryptedMedia>) -> some View {

        switch item.mediaType {
        case .stillPhoto:
            let model = viewModel.modelForMedia(item: item)
            ImageViewing(viewModel: model, externalGesture: dragGestureRef)
                .onDisappear {
                    model.resetViewState()
                }
        case .livePhoto:
            LivePhotoViewing(viewModel: .init(sourceMedia: item, fileAccess: viewModel.fileAccess, delegate: viewModel), externalGesture: dragGestureRef)
        case .video:
            MovieViewing(viewModel: .init(media: item, fileAccess: viewModel.fileAccess, delegate: viewModel), isPlayingVideo: $viewModel.isPlayingVideo)
        }
    }

    private var actionBar: some View {
        ZStack {
            HStack {
                Spacer()

                Group {
                    if viewModel.canAccessPhoto(at: viewModel.selectedIndex) {
                        Menu {
                            Button {
                                showingShareSheet = true
                            } label: {
                                Label(L10n.shareThisImage, systemImage: "square.and.arrow.up")
                            }
                            Button {
                                viewModel.showInfoSheet = true
                            } label: {
                                Label("Info", systemImage: "info.circle")
                            }
                            Button {
                                showingDeleteConfirmation = true
                            } label: {
                                Label(L10n.delete, systemImage: "trash")
                            }
                        } label: {
                            Image("Album-OptionsDots")
                        }
                    }
                }
            }
            .padding()
            .frame(height: 44)

        }
    }
    private func scrollTo(media: InteractableMedia<EncryptedMedia>?, with proxy: ScrollViewProxy, animated: Bool = true) {
        guard let media else { return }
        let scrollClosure = {
            proxy.scrollTo(media.id, anchor: nil)
        }
        if animated {
            withAnimation {
                scrollClosure()
            }
        } else {
            scrollClosure()
        }

    }

}

struct GalleryHorizontalScrollView_Previews: PreviewProvider {
    static var previews: some View {
        let media = (0..<10).map { try! InteractableMedia<EncryptedMedia>(underlyingMedia: [.init(source: URL(string: "/")!, mediaType: .photo, id: "\($0)")])
        }
        let model = GalleryHorizontalScrollViewModel(media: media, initialMedia: media.first!, fileAccess: DemoFileEnumerator(), purchasedPermissions: AppPurchasedPermissionUtils())
        GalleryHorizontalScrollView(viewModel: model)
            .preferredColorScheme(.dark)
    }
}
