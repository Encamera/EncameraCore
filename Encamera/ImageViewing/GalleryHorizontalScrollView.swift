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

private struct OffsetPreferenceKey: PreferenceKey {
    
    static var defaultValue: CGPoint = .zero
    
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { }
}

struct ScrollViewOffsetPreferenceKey: PreferenceKey {
    static var defaultValue = CGFloat.zero
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}
// A ScrollView wrapper that tracks scroll offset changes.
struct ObservableScrollView<Content>: View where Content : View {
    @Namespace var scrollSpace
    
    @Binding var scrollOffset: CGFloat
    let content: (ScrollViewProxy) -> Content
    
    init(scrollOffset: Binding<CGFloat>,
         @ViewBuilder content: @escaping (ScrollViewProxy) -> Content) {
        _scrollOffset = scrollOffset
        self.content = content
    }
    
    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                content(proxy)
                    .background(GeometryReader { geo in
                        let offset = -geo.frame(in: .named(scrollSpace)).minY
                        Color.clear
                            .preference(key: ScrollViewOffsetPreferenceKey.self,
                                        value: offset)
                    })
            }
        }
        .coordinateSpace(name: scrollSpace)
        .onPreferenceChange(ScrollViewOffsetPreferenceKey.self) { value in
            scrollOffset = value
        }
    }
}

struct GalleryHorizontalScrollView: View {
    
    @ObservedObject var viewModel: GalleryHorizontalScrollViewModel
    @Binding var shouldShow: Bool
    @State var scrollViewXOffset: CGFloat = .zero
    @GestureState private var state = false
    //    @Published var startPoint: CGPoint = .zero
    @Namespace var scrollSpace

    
    
    var body: some View {
        VStack {
            
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                let gridItems = [
                    GridItem(.fixed(frame.width), spacing: 0)
                ]
                ScrollView(.horizontal) {

                ScrollViewReader { scrollProxy in
                    
                        
                        LazyHGrid(rows: gridItems) {
                            ForEach(viewModel.media, id: \.id) { item in
                                ImageViewing(viewModel:
                                        .init(media: item, fileAccess: viewModel.fileAccess),
                                             isActive: $shouldShow)
                                
                                .frame(width: frame.width, height: frame.height)
                                
                            }
                        }.background(GeometryReader { geo in
                            let offset = -geo.frame(in: .named(scrollSpace)).minY
                            Color.clear
                                .preference(key: ScrollViewOffsetPreferenceKey.self,
                                            value: offset)
                        })
                    }
//                    .onAppear {
//                        scrollProxy.scrollTo(viewModel.selectedMedia.id)
//                    }
                }
                .coordinateSpace(name: scrollSpace)
                .onPreferenceChange(ScrollViewOffsetPreferenceKey.self) { value in
                    print("Scroll view value", value)
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
