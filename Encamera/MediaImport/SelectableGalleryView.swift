//
//  File.swift
//  Encamera
//
//  Created by Alexander Freas on 10.05.23.
//

import Foundation
import SwiftUI
import EncameraCore

class SelectableGalleryViewModel: ObservableObject {
    
    @Published var isSelecting: Bool = true
    @Published var media: [InteractableMedia<EncryptedMedia>]
    @Published var carouselTarget: InteractableMedia<EncryptedMedia>?
    @Published var selectedMedia: Set<InteractableMedia<EncryptedMedia>> = Set()
    var fileAccess: FileReader
    
    init(media: [InteractableMedia<EncryptedMedia>], fileAccess: FileReader) {
        self.media = media
        self.fileAccess = fileAccess
    }
    
    func toggleSelectedMedia(_ media: InteractableMedia<EncryptedMedia>) {
        if selectedMedia.contains(media) {
            selectedMedia.remove(media)
        } else {
            selectedMedia.insert(media)
        }
    }
}
private enum Constants {
    static let hideButtonWidth = 100.0
    static let numberOfImagesWide = 3.0
}


struct SelectableGalleryView<T: MediaDescribing>: View  {
    
    @StateObject var viewModel: SelectableGalleryViewModel

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let side = frame.width / Constants.numberOfImagesWide
            let gridItems = [
                GridItem(.fixed(side), spacing: 1),
                GridItem(.fixed(side), spacing: 1),
                GridItem(.fixed(side), spacing: 1)
            ]
            ScrollView {
                LazyVGrid(columns: gridItems, spacing: 1) {
                    ForEach(Array(viewModel.media.enumerated()), id: \.element) { index, mediaItem in
                        let selectionBinding = Binding<Bool> {
                            viewModel.selectedMedia.contains(mediaItem)
                        } set: { selected, _ in
                            if selected {
                                viewModel.selectedMedia.insert(mediaItem)
                            } else {
                                viewModel.selectedMedia.remove(mediaItem)
                            }
                        }
                        
                        AsyncEncryptedImage(viewModel: .init(targetMedia: mediaItem, loader: viewModel.fileAccess), placeholder: ProgressView(), isInSelectionMode: $viewModel.isSelecting, isSelected: selectionBinding)
                            .onTapGesture {
                                if viewModel.isSelecting {
                                    viewModel.toggleSelectedMedia(mediaItem)
                                } else {
                                    viewModel.carouselTarget = mediaItem
                                }
                            }
                    }
                }
            }
        }
    }
}

//struct SelectableGalleryView_Previews: PreviewProvider {
//    
//    public static func withUrl() -> CleartextMedia<URL> {
//        guard let url = Bundle.main
//            .url(forResource: "3", withExtension: "JPG") else {
//            fatalError()
//        }
//        return CleartextMedia(source: url)
//    }
//    
//    public static var media: [CleartextMedia<URL>] {
//        (1..<6).map { i in
//            guard let url = Bundle.main
//                .url(forResource: "\(i)", withExtension: "JPG") else {
//                fatalError()
//            }
//            return CleartextMedia(source: url)
//
//        }
//    }
//    
//    static var previews: some View {
//        SelectableGalleryView(viewModel: .init(media: media, fileAccess: DemoFileEnumerator()))
//    }
//}
