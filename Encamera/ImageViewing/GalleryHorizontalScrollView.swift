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
    
    @Published var media: [EncryptedMedia]
    @Published var selectedMedia: EncryptedMedia?
    @Published var showInfoSheet = false
    @Published var showPurchaseSheet = false
    @Published var isPlayingVideo = false
    var purchasedPermissions: PurchasedPermissionManaging
    var showActionBar = true
    var fileAccess: FileAccess
    private var cancellables = Set<AnyCancellable>()
    
    init(media: [EncryptedMedia], selectedMedia: EncryptedMedia, fileAccess: FileAccess, showActionBar: Bool = true, purchasedPermissions: PurchasedPermissionManaging) {
        self.media = media
        self.fileAccess = fileAccess
        self.selectedMedia = selectedMedia
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

            await MainActor.run {
                _ = withAnimation {
                    media.remove(at: targetIndex)
                }
            }
            do {
                try await fileAccess.delete(media: targetMedia)
            } catch {
                debugPrint("Error deleting media", error)
            }
        }
    }
    var imageModels: [EncryptedMedia.ID: ImageViewingViewModel<EncryptedMedia>] = [:]
    func modelForMedia(item: EncryptedMedia) -> ImageViewingViewModel<EncryptedMedia> {
        if let model = imageModels[item.id] {
            return model
        } else {
            let model = ImageViewingViewModel(swipeLeft: {
            }, swipeRight: {

            }, sourceMedia: item, fileAccess: fileAccess)
            imageModels[item.id] = model
            return model
        }

    }
    
    @MainActor
    func shareEncrypted() {
        guard let selectedMedia else { return }
        shareSheet(data: selectedMedia.source)
    }
    
    func shareDecrypted() {
        guard let selectedMedia else { return }
        Task {
            switch selectedMedia.mediaType {
            case .photo:
                let decrypted = try await fileAccess.loadMediaInMemory(media: selectedMedia) { _ in
                    
                }
                await MainActor.run {
                    if let image = UIImage(data: decrypted.source) {
                        shareSheet(data: image)
                    }
                }
                
            case .video:
                let decrypted = try await fileAccess.loadMediaToURL(media: selectedMedia) {_ in
                    
                }
                await MainActor.run {
                    shareSheet(data: decrypted.source)
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
                        scrollTo(media: viewModel.selectedMedia, with: proxy, animated: false)
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


    @ViewBuilder private func viewingFor(item: EncryptedMedia) -> some View {

        switch item.mediaType {
        case .photo:
            let model = viewModel.modelForMedia(item: item)
            ImageViewing(viewModel: model, externalGesture: dragGestureRef)
                .onDisappear {
                    model.resetViewState()
                }
        case .video:
            MovieViewing(viewModel: .init(media: item, fileAccess: viewModel.fileAccess), isPlayingVideo: $viewModel.isPlayingVideo)
        default:
            EmptyView()

        }
    }
    
    private var actionBar: some View {
        HStack(alignment: .center) {
            Group {
                if viewModel.canAccessPhoto(at: viewModel.selectedIndex) {
                    Button {
                        showingShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button {
                        viewModel.showInfoSheet = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(height: 44)
    }
    
    private func scrollTo(media: EncryptedMedia?, with proxy: ScrollViewProxy, animated: Bool = true) {
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
        let media = (0..<10).map { EncryptedMedia(source: URL(string: "/")!, mediaType: .photo, id: "\($0)") }
        let model = GalleryHorizontalScrollViewModel(media: media, selectedMedia: media.first!, fileAccess: DemoFileEnumerator(), purchasedPermissions: AppPurchasedPermissionUtils())
        GalleryHorizontalScrollView(viewModel: model)
            .preferredColorScheme(.dark)
    }
}
