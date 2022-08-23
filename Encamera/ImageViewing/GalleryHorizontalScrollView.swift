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
    
    init(media: [EncryptedMedia], selectedMedia: EncryptedMedia, fileAccess: FileAccess) {
        self.media = media
        self.fileAccess = fileAccess
        self.selectedMedia = selectedMedia
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
    
    @ObservedObject var viewModel: GalleryHorizontalScrollViewModel
    @Binding var shouldShow: Bool
    @State var scrollViewXOffset: CGFloat = .zero
    @GestureState private var state = false
    var swipeDownGesture = DragGesture()
    //    @Published var startPoint: CGPoint = .zero
    
    
    
    var body: some View {
        VStack {
            Button {
                shouldShow = false
            } label: {
                Image(systemName: "x.circle")
            }
            
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                let gridItems = [
                    GridItem(.fixed(frame.width), spacing: 0)
                ]
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: gridItems) {
                            ForEach(viewModel.media, id: \.id) { item in
                                ImageViewing(viewModel:
                                        .init(media: item, fileAccess: viewModel.fileAccess),
                                             isActive: $shouldShow)
                                .frame(width: frame.width, height: frame.height)
                            }
                        }
                    }.onAppear {
                        scrollProxy.scrollTo(viewModel.selectedMedia.id)
                    }
                }
            }
        }
    }
}

struct GalleryHorizontalScrollView_Previews: PreviewProvider {
    static var previews: some View {
        let media = (0..<10).map { EncryptedMedia(source: URL(string: "/")!, mediaType: .photo, id: "\($0)") }
        let model = GalleryHorizontalScrollViewModel(media: media, selectedMedia: media.first!, fileAccess: DemoFileEnumerator())
        GalleryHorizontalScrollView(viewModel: model, shouldShow: .constant(false))
    }
}
