//
//  GalleryHorizontalScrollView.swift
//  Encamera
//
//  Created by Alexander Freas on 16.08.22.
//

import SwiftUI
import Combine
import EncameraCore


class GalleryHorizontalScrollViewModel: ObservableObject {
    
    @Published var media: [InteractableMedia<EncryptedMedia>]
    @Published var selectedMedia: InteractableMedia<EncryptedMedia>?
    @Published var initialMedia: InteractableMedia<EncryptedMedia>?
    @Published var showInfoSheet = false
    @Published var showPurchaseSheet = false
    @Published var isPlayingVideo = false
    @Published var isPlayingLivePhoto = false
    var purchasedPermissions: PurchasedPermissionManaging
    var showActionBar = true
    var fileAccess: FileAccess
    private var cancellables = Set<AnyCancellable>()
    
    init(media: [InteractableMedia<EncryptedMedia>], initialMedia: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, showActionBar: Bool = true, purchasedPermissions: PurchasedPermissionManaging) {
        self.media = media
        self.fileAccess = fileAccess
        self.initialMedia = initialMedia
        self.showActionBar = showActionBar
        self.purchasedPermissions = purchasedPermissions
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
    
    func shareDecrypted() {
        guard let selectedMedia else { return }
        Task {
            #warning("implement live photo sharing")
            let decrypted = try await fileAccess.loadMedia(media: selectedMedia) { _ in

            }
            switch selectedMedia.mediaType {
            case .livePhoto, .stillPhoto:

                guard let data = decrypted.imageData else {
                    return
                }

                await MainActor.run {
                    if let image = UIImage(data: data) {
                        shareSheet(data: image)
                    }
                }
                
            case .video:
                await MainActor.run {
                    shareSheet(data: decrypted.videoURL)
                }
            default:
                return
            }
            
        }
    }
    @MainActor
    func shareSheet(data: Any) {
        let activityView = UIActivityViewController(activityItems: [data], applicationActivities: nil)
        
        
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

extension GalleryHorizontalScrollViewModel: MediaViewingDelegate {
    func didView(media: InteractableMedia<EncryptedMedia>) {
        self.selectedMedia = media
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
                .screenBlocked()
                .onChange(of: viewModel.isPlayingVideo) {
                    isScrollEnabled = !viewModel.isPlayingVideo
                }
            }
            if viewModel.showActionBar {
                actionBar
            }
        }
        .sheet(isPresented: $viewModel.showInfoSheet) {
            let content = Group {
                if let media = viewModel.selectedMedia {
                    PhotoInfoView(media: media, isPresented: $viewModel.showInfoSheet)
                } else {
                    EmptyView()
                }
            }
            if #available(iOS 16.0, *) {
                VStack {
                    content
                }
                .presentationDetents([.fraction(0.2)])
            } else {
                VStack {
                    content
                }
            }
        }
        .productStore(isPresented: $viewModel.showPurchaseSheet, fromViewName: viewTitle)
    }
    
    
    @ViewBuilder private func scrollView(frame: CGRect) -> some View {
        let gridItems = [
            GridItem(.fixed(frame.width), spacing: 0)
        ]

        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHGrid(rows: gridItems) {
                    ForEach(Array(viewModel.media.enumerated()), id: \.element.id) { index, item in
                        ZStack {
                            let modalBinding = Binding<Bool> {
                                !viewModel.canAccessPhoto(at: index)
                            } set: { _ in

                            }
                            viewingFor(item: item)
                                .blur(radius:
                                        viewModel.canAccessPhoto(at: index)
                                      ? 0.0 : AppConstants.blockingBlurRadius)
                                .frame(
                                    width: frame.width,
                                    height: frame.height)
                                .photoLimitReachedModal(isPresented: modalBinding) {
                                    viewModel.showPurchaseScreen()
                                    EventTracking.trackPhotoLimitReachedScreenUpgradeTapped(from: "ImageScrollView")
                                } onSecondaryButtonPressed: {
                                    EventTracking.trackPhotoLimitReachedScreenDismissed(from: "ImageScrollView")
                                    dismiss()
                                }

                        }
                        .id(item)
                        .clipped()
                    }.onAppear {
                        scrollTo(media: viewModel.initialMedia, with: proxy, animated: false)
                    }

                }
                .scrollTargetLayout()
                .frame(maxHeight: .infinity)
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
        ZStack {
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
