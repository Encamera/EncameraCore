//
//  GalleryHorizontalScrollView.swift
//  Encamera
//
//  Created by Alexander Freas on 16.08.22.
//

import SwiftUI
import Combine
import SwiftUISnappingScrollView

class GalleryHorizontalScrollViewModel: ObservableObject {
    
    @Published var media: [EncryptedMedia]
    @Published var selectedMedia: EncryptedMedia
    var fileAccess: FileAccess
    private var cancellables = Set<AnyCancellable>()
    
    init(media: [EncryptedMedia], selectedMedia: EncryptedMedia, fileAccess: FileAccess) {
        self.media = media
        self.fileAccess = fileAccess
        self.selectedMedia = selectedMedia
    }
    
    var selectedIndex: Int {
        media.firstIndex(of: selectedMedia) ?? 0
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
            let targetMedia = selectedMedia
            try await fileAccess.delete(media: targetMedia)
            media.removeAll { $0 == targetMedia }
            rewindIndex()
        }
    }
    
}
extension Color {
    static var random: Color {
        return Color(
            red: .random(in: 0...1),
            green: .random(in: 0...1),
            blue: .random(in: 0...1)
        )
    }
}

struct GalleryHorizontalScrollView: View {
    
    
    typealias MagnificationGestureType = _EndedGesture<_ChangedGesture<GestureStateGesture<MagnificationGesture, Bool>>>
    typealias TapGestureType = _EndedGesture<TapGesture>
    typealias DragGestureType = _EndedGesture<_ChangedGesture<DragGesture>>

    
    @ObservedObject var viewModel: GalleryHorizontalScrollViewModel
    @Binding var shouldShow: Bool
    @State var nextScrollViewXOffset: CGFloat = .zero
    //    @Published var startPoint: CGPoint = .zero
    @Namespace var scrollSpace
    @GestureState private var state = false
    @State var currentScrollViewXOffset: CGFloat = .zero
    @State var isDragging = false
    @State var finalScale: CGFloat = 1.0
    @State var currentScale: CGFloat = .zero
    @State var finalOffset: CGSize = .zero
    @State var currentOffset: CGSize = .zero
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
                return finalScale + currentScale
            } else {
                return 1.0
            }
        } set: { _, _ in
            
        }
    }
    
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            ZStack {
                VStack {
                    
                    let gridItems = [
                        GridItem(.fixed(frame.width), spacing: 0)
                    ]
                    ScrollViewReader { proxy in
                        
                        ScrollView(.horizontal) {
                            
                            LazyHGrid(rows: gridItems) {
                                ForEach(viewModel.media, id: \.id) { item in
                                    
                                    let model = ImageViewingViewModel(media: item, fileAccess: viewModel.fileAccess)
                                    
                                    ImageViewing(
                                        currentScale: scaleBinding(for: item),
                                        finalOffset: offsetBinding(for: item),
                                        isActive: $shouldShow,
                                        
                                        viewModel: model, externalGesture: dragGestureRef)
                                    .frame(width: frame.width, height: frame.height)
                                    
                                }
                            }
                        }
                        .onChange(of: viewModel.selectedMedia) { newValue in
                            scrollTo(media: newValue, with: proxy)
                        }
                        .onAppear {
                            scrollTo(media: viewModel.selectedMedia, with: proxy)
                        }
                        
                    }
                }.gesture(dragGesture(with: frame)
                    .simultaneously(with: magnificationGesture)
                    .simultaneously(with: tapGesture)
                )
            }
            VStack {
                Spacer()
                HStack(alignment: .center) {
                    Button {
                    
                        
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }.contextMenu {
                        Button("Share Encrypted") {
                            shareSheet(data: viewModel.selectedMedia.source)
                        }
                        Button("Share Decrypted") {
                            Task {
                                let decrypted = try await viewModel.fileAccess.loadMediaInMemory(media: viewModel.selectedMedia) { _ in
                                    
                                }
                                await MainActor.run {
                                    let image = UIImage(data: decrypted.source)!
                                    shareSheet(data: image)
                                }
                            }
                        }
                    }
                    Spacer()
                    Button {
                        let url = URL(string: "shareddocuments://\(viewModel.selectedMedia.source.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)")!
                        UIApplication.shared.open(url)
                    } label: {
                        Image(systemName: "folder")
                    }
                    Spacer()
                    Button {
                        viewModel.deleteAction()
                    } label: {
                        Image(systemName: "trash")
                    }

                }.padding()
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
    
    private func scrollTo(media: EncryptedMedia, with proxy: ScrollViewProxy) {
        withAnimation {
            finalScale = 1.0
            proxy.scrollTo(media.id)
        }

    }
    private func dragGesture(with frame: CGRect) -> DragGestureType {
        dragGestureRef.onChanged({ value in
            if finalScale > 1.0 {
                var newOffset = value.translation
                if newOffset.height > frame.height * finalScale {
                    newOffset.height = frame.height * finalScale
                }
                
                currentOffset = newOffset
            }
            
        }).onEnded({ value in
            if finalScale <= 1.0 {
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
        MagnificationGesture().updating($state, body: { value, state, transaction in
            print(value, state, transaction)
        }).onChanged({ value in
            currentScale = value - 1
            
        })
            .onEnded({ amount in
                let final = finalScale + currentScale
                finalScale = final < 1.0 ? 1.0 : final
                currentScale = 0.0
            })
    }
}

struct GalleryHorizontalScrollView_Previews: PreviewProvider {
    static var previews: some View {
        let media = (0..<10).map { EncryptedMedia(source: URL(string: "/")!, mediaType: .photo, id: "\($0)") }
        let model = GalleryHorizontalScrollViewModel(media: media, selectedMedia: media.first!, fileAccess: DemoFileEnumerator())
        GalleryHorizontalScrollView(viewModel: model, shouldShow: .constant(false))
    }
}
