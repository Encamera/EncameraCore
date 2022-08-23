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
    @Published var xOffset: CGFloat = .zero
    var fileAccess: FileAccess
    private var cancellables = Set<AnyCancellable>()

    init(media: [EncryptedMedia], selectedMedia: EncryptedMedia, fileAccess: FileAccess) {
        self.media = media
        self.fileAccess = fileAccess
        self.selectedMedia = selectedMedia
        
        $xOffset.debounce(for: .seconds(0.2), scheduler: DispatchQueue.main).sink { value in
            print("debounced value", value)
        }.store(in: &cancellables)
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
    @GestureState private var state = true

    var body: some View {
        let dragGesture = DragGesture(minimumDistance: 1).onEnded({ ended in
            print("ended")
        }).updating($state, body: { value, state, transaction in
            print("drag", value, state, transaction)
        })
        ScrollView(.horizontal) {
            ScrollViewReader { proxy in
                content(proxy)

                    .background(GeometryReader { geo in
                        let offset = -geo.frame(in: .named(scrollSpace)).minX
                            
                        Color.clear
                            .gesture(dragGesture)
                            .preference(key: ScrollViewOffsetPreferenceKey.self,
                                        value: offset)
                    })
            }
        }
//        .gesture(dragGesture)
//        .simultaneousGesture(dragGesture)
        .coordinateSpace(name: scrollSpace)
        .onPreferenceChange(ScrollViewOffsetPreferenceKey.self) { value in
            scrollOffset = value
        }
    }
}

struct GalleryHorizontalScrollView: View {
    
    
    @ObservedObject var viewModel: GalleryHorizontalScrollViewModel
    @Binding var shouldShow: Bool
    var scrollViewXOffset: CGFloat = .zero
    //    @Published var startPoint: CGPoint = .zero
    @Namespace var scrollSpace
    
   
    
    var body: some View {

        let scrollViewXOffsetBinding = Binding(get: {
            viewModel.xOffset
        }, set: { value in
            viewModel.xOffset = value
        })
        
       
        VStack {
            
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                let gridItems = [
                    GridItem(.fixed(frame.width), spacing: 0)
                ]
                ObservableScrollView(scrollOffset: scrollViewXOffsetBinding) { proxy in
                    
                    LazyHGrid(rows: gridItems) {
                        ForEach(viewModel.media, id: \.id) { item in
//                            ImageViewing(isActive: $shouldShow, viewModel:
//                                    .init(media: item, fileAccess: viewModel.fileAccess))
                            Color.orange
                            .frame(width: frame.width, height: frame.height)
                            
                        }
                    }
                    
                    .onAppear {
                        proxy.scrollTo(viewModel.selectedMedia.id)
                    }
//                    .onChange(of: ) { newValue in
//                        if newValue.truncatingRemainder(dividingBy: frame.width) > frame.width / 2 {
//                            print("scroll right")
//                        } else {
//                            print("scroll left")
//                        }
//
//                        print("onchange value", newValue)
//                    }
                    
                }
            }
        }
    }
}

//struct GalleryHorizontalScrollView_Previews: PreviewProvider {
//    static var previews: some View {
//        let media = (0..<10).map { EncryptedMedia(source: URL(string: "/")!, mediaType: .photo, id: "\($0)") }
//        let model = GalleryHorizontalScrollViewModel(media: media, selectedMedia: media.first!, fileAccess: DemoFileEnumerator())
//        GalleryHorizontalScrollView(viewModel: model, shouldShow: .constant(false))
//    }
//}
