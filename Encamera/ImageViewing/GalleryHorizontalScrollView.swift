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
    var fileAccess: FileAccess
    
    init(media: [EncryptedMedia], fileAccess: FileAccess) {
        self.media = media
        self.fileAccess = fileAccess
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
    @State var scrollViewXOffset: CGFloat = .zero

    var body: some View {
        
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let gridItems = [
                GridItem(.fixed(frame.width), spacing: 0)
            ]
            
            ScrollView(.horizontal) {
                LazyHGrid(rows: gridItems) {

                    ForEach(viewModel.media) { item in
//            let item = viewModel.media.first!
                        ImageViewing(viewModel: .init(media: item, fileAccess: viewModel.fileAccess)).frame(width: frame.width, height: frame.height)
                            
                    }
                }
            }
        }
    }
}

struct GalleryHorizontalScrollView_Previews: PreviewProvider {
    static var previews: some View {
        let media = (0..<10).map { EncryptedMedia(source: URL(string: "/")!, mediaType: .photo, id: "\($0)") }
        let model = GalleryHorizontalScrollViewModel(media: media, fileAccess: DemoFileEnumerator())
        GalleryHorizontalScrollView(viewModel: model)
    }
}
