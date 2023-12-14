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
    @Published var selectedMedia: EncryptedMedia
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
        media.firstIndex(of: selectedMedia) ?? 0
    }
    
    func openInFiles() {
        LocalDeeplinkingUtils.openInFiles(media: selectedMedia)
    }
    
    func advanceIndex() {
        let nextIndex = min(media.count - 1, selectedIndex + 1)
        selectedMedia = media[nextIndex]
        
    }
    
    func rewindIndex() {
        let nextIndex = max(0, selectedIndex - 1)
        selectedMedia = media[nextIndex]
    }
    
    func deleteAction() {
        Task {
            let targetIndex = selectedIndex
            let targetMedia = selectedMedia
            
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

    
    func shareEncrypted() {
        shareSheet(data: selectedMedia.source)
    }
    
    func shareDecrypted() {
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
    
    func shareSheet(data: Any) {
        let activityView = UIActivityViewController(activityItems: [data], applicationActivities: nil)
        
        
        let allScenes = UIApplication.shared.connectedScenes
        let scene = allScenes.first { $0.activationState == .foregroundActive }
        
        if let windowScene = scene as? UIWindowScene {
            windowScene.keyWindow?.rootViewController?.present(activityView, animated: true, completion: nil)
        }
        
    }
    
    func canAccessPhoto(at index: Int) -> Bool {
        return purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: Double(media.count - index)))
    }
    
    func showPurchaseScreen() {
        showPurchaseSheet = true
    }
    
}

struct GalleryHorizontalScrollView: View {
    
    
    typealias MagnificationGestureType = _EndedGesture<_ChangedGesture<MagnificationGesture>>
    typealias TapGestureType = _EndedGesture<TapGesture>
    typealias DragGestureType = _EndedGesture<_ChangedGesture<DragGesture>>
    
    struct GestureModifier: ViewModifier {
        let isPlayingVideo: Bool
        let dragGesture: DragGestureType
        let magnificationGesture: MagnificationGestureType
        let tapGesture: TapGestureType
        
        func body(content: Content) -> some View {
            if isPlayingVideo {
                content
            } else {
                content
                    .gesture(dragGesture)
                    .gesture(magnificationGesture)
                    .gesture(tapGesture)
            }
        }
    }
    @State var isGesturesDisabled = false

    
    @StateObject var viewModel: GalleryHorizontalScrollViewModel
    @State var nextScrollViewXOffset: CGFloat = .zero
    @Namespace var scrollSpace
    @GestureState private var state = false
    @State var finalScale: CGFloat = 1.0
    @State var currentScale: CGFloat = 1.0
    @State var finalOffset: CGSize = .zero
    @State var currentOffset: CGSize = .zero
    @State var showingShareSheet = false
    @State var showingDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss
    var dragGestureRef = DragGesture(minimumDistance: 0)
    
    
    func offsetBinding(for item: EncryptedMedia) -> Binding<CGSize> {
        return Binding<CGSize> {
            if viewModel.selectedMedia == item {
                return CGSize(
                    width: finalOffset.width + currentOffset.width,
                    height: finalOffset.height + currentOffset.height)
            } else {
                return .zero
            }
        } set: { _ in
            
        }
        
    }
    
    func scaleBinding(for item: EncryptedMedia) -> Binding<CGFloat> {
        return Binding<CGFloat> {
            if viewModel.selectedMedia == item {
                return finalScale * currentScale
            } else {
                return 1.0
            }
        } set: { _, _ in
            
        }
    }
    
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
                .gesture(dragGesture(with: frame))
                .gesture(isGesturesDisabled ? nil : magnificationGesture)
                .onChange(of: viewModel.isPlayingVideo) { isPlaying in
                    isGesturesDisabled = isPlaying
                }
            }
            if viewModel.showActionBar {
                actionBar
            }
        }
        .sheet(isPresented: $viewModel.showInfoSheet) {
            let content = Group {
                PhotoInfoView(media: viewModel.selectedMedia, isPresented: $viewModel.showInfoSheet)
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
        .sheet(isPresented: $viewModel.showPurchaseSheet) {
            ProductStoreView(fromView: "ImageScrollView")
        }
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
                            viewingFor(item: item)
                                .blur(radius:
                                        viewModel.canAccessPhoto(at: index)
                                      ? 0.0 : AppConstants.blockingBlurRadius)
                                .frame(
                                    width: frame.width,
                                    height: frame.height)
                                .photoLimitReachedModal(isPresented: !viewModel.canAccessPhoto(at: index)) {
                                    viewModel.showPurchaseScreen()
                                    EventTracking.trackPhotoLimitReachedScreenUpgradeTapped(from: "ImageScrollView")
                                } onSecondaryButtonPressed: {
                                    EventTracking.trackPhotoLimitReachedScreenDismissed(from: "ImageScrollView")
                                    dismiss()
                                }
                        }.clipped()

                    }
                }.frame(maxHeight: .infinity)
            }
            .onChange(of: viewModel.selectedMedia) { newValue in
                viewModel.isPlayingVideo = false
                scrollTo(media: newValue, with: proxy)
            }
            .onAppear {
                scrollTo(media: viewModel.selectedMedia, with: proxy, animated: false)
            }
        }.scrollIndicators(.hidden)
    }
    @ViewBuilder private func viewingFor(item: EncryptedMedia) -> some View {
        switch item.mediaType {
        case .photo:
            let model = ImageViewingViewModel(media: item, fileAccess: viewModel.fileAccess)
            ImageViewing(
                currentScale: scaleBinding(for: item),
                finalOffset: offsetBinding(for: item),
                viewModel: model, externalGesture: dragGestureRef)
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
                        viewModel.openInFiles()
                    } label: {
                        Image(systemName: "folder")
                    }
                    Button {
                        viewModel.showInfoSheet = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(height: 44)
    }
    
    private func scrollTo(media: EncryptedMedia, with proxy: ScrollViewProxy, animated: Bool = true) {
        let scrollClosure = {
            resetViewState()
            proxy.scrollTo(media.id, anchor: .center)
        }
        if animated {
            withAnimation {
                scrollClosure()
            }
        } else {
            scrollClosure()
        }

    }
    
    private func resetViewState() {
        finalScale = 1.0
        currentScale = 1.0
        finalOffset = .zero
        currentOffset = .zero

    }
    private func didResetViewStateIfNeeded() -> Bool {
        debugPrint("didResetViewStateIfNeeded: finalScale \(finalScale), finalOffset \(finalOffset), currentOffset \(currentOffset), currentScale \(currentScale)")

        if finalScale <= 1.0 && finalOffset != .zero {
            resetViewState()
            return true
        }
        return false
    }
    
    private func dragGesture(with frame: CGRect) -> DragGestureType {
        
        dragGestureRef.onChanged({ value in
            guard isGesturesDisabled == false else {
                return
            }
            if finalScale > 1.0 {
                var newOffset = value.translation
                if newOffset.height > frame.height * finalScale {
                    newOffset.height = frame.height * finalScale
                }

                currentOffset = newOffset
            }
            
        }).onEnded({ value in
            if didResetViewStateIfNeeded() {
                return
            }
            if finalScale <= 1.0 {
                if value.location.x > value.startLocation.x {
                    viewModel.rewindIndex()
                } else {
                    viewModel.advanceIndex()
                }
            } else {
                let nextOffset: CGSize = .init(
                    width: finalOffset.width + currentOffset.width,
                    height: finalOffset.height + currentOffset.height)

                finalOffset = nextOffset
                currentOffset = .zero

            }
            
        })
    }
    
    private var tapGesture: TapGestureType {
        TapGesture(count: 2).onEnded {
            finalScale = finalScale > 1.0 ? 1.0 : 3.0
            finalOffset = .zero
        }
    }
    
    private var magnificationGesture: MagnificationGestureType {
        MagnificationGesture().onChanged({ value in
            currentScale = 	value
        })
        .onEnded({ amount in
            if didResetViewStateIfNeeded() {
                return
            }
            let final = finalScale * currentScale
            finalScale = final < 1.0 ? 1.0 : final
            currentScale = 1.0
        })
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
