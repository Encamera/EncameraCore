//
//  GalleryView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI

struct LocalImageView: View {
    
    var imageModel: ShadowPixMedia
    
    var body: some View {
        Group {
            if let image = imageModel.decryptedImage?.image {
                Image(uiImage: image)
            }
        }.onAppear {
            imageModel.loadImage()
        }
    }
}

struct AsyncImage<Placeholder: View>: View {
    
    private var placeholder: Placeholder
    private var loader: FileReader
    @ObservedObject private var media: ShadowPixMedia
    
    init(_ media: ShadowPixMedia, loader: FileReader, placeholder: () -> Placeholder) {
        self.loader = loader
        self.placeholder = placeholder()
        self.media = media
    }
    
    var body: some View {
        
        content.onAppear {
            loader.loadMediaPreview(for: media)
        }
    }
    
    private var content: some View {
        Group {
            // need separate view for holding preview
            if let decrypted = media.decryptedImage?.image {
                Image(uiImage: decrypted)
                    .resizable()
                    .clipped()
                    .aspectRatio(contentMode:.fit)
            } else {
                placeholder
            }
        }
    }
}

class GalleryViewModel: ObservableObject {
    @Published var fileEnumerator: FileAccess
    
    init(fileEnumerator: FileAccess) {
        self.fileEnumerator = fileEnumerator
    }
}

struct GalleryView: View {
    
    @EnvironmentObject var state: ShadowPixState
    @State private var images: [ShadowPixMedia] = []
    @State var displayImage: ShadowPixMedia?
    @State var isDisplayingImage: Bool = false
    @ObservedObject var viewModel: GalleryViewModel

    
    var body: some View {
        let gridItems = [
            GridItem(.adaptive(minimum: 100))
        ]
            ScrollView {
//                NavigationLink("", isActive: $isDisplayingImage) {
//                    if let displayImage = displayImage {
//                        ImageViewing(viewModel: .init(image: displayImage))
//                    } else {
//                        EmptyView()
//                    }
//                }
                LazyVGrid(columns: gridItems, spacing: 1) {
                    ForEach(images, id: \.id) { image in
                        AsyncImage(image, loader: viewModel.fileEnumerator) {
                            Color.gray.frame(width: 50, height: 50)
                        }.onTapGesture {
                            self.displayImage = image
                            self.isDisplayingImage = true
                        }
                    }
                    
                }.padding(.horizontal)
            }
        .onReceive(viewModel.$fileEnumerator, perform: { x in
            viewModel.fileEnumerator.enumerateMedia { images in
                self.images = images
            }
        })
        .onAppear {
            viewModel.fileEnumerator.enumerateMedia { images in
                self.images = images
            }
        }.edgesIgnoringSafeArea(.all)
    }
}

struct GalleryView_Previews: PreviewProvider {

    static var previews: some View {
        let enumerator = DemoFileEnumerator(directoryModel: DemoDirectoryModel(), key: nil)
        GalleryView(viewModel: GalleryViewModel(fileEnumerator: enumerator)).environmentObject(ShadowPixState(fileHandler: enumerator))
    }
}
