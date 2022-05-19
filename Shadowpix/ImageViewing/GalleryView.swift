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

struct AsyncImage<Placeholder: View, Enumerator: FileEnumerator>: View {
    
    private var placeholder: Placeholder
    private var loader: Enumerator
    @ObservedObject private var media: ShadowPixMedia
    
    init(_ media: ShadowPixMedia, loader: Enumerator, placeholder: () -> Placeholder) {
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

class GalleryViewModel<Enumerator: FileEnumerator>: ObservableObject {
    @Published var fileEnumerator: Enumerator
    
    init(fileEnumerator: Enumerator) {
        self.fileEnumerator = fileEnumerator
    }
}

struct GalleryView<Enumerator: FileEnumerator>: View {
    
    @EnvironmentObject var state: ShadowPixState
    @State private var images: [ShadowPixMedia] = []
    @State var displayImage: ShadowPixMedia?
    @State var isDisplayingImage: Bool = false
    @ObservedObject var viewModel: GalleryViewModel<Enumerator>

    
    var body: some View {
        let gridItems = [
            GridItem(.adaptive(minimum: 100))
        ]
            ScrollView {
                NavigationLink("", isActive: $isDisplayingImage) {
                    if let displayImage = displayImage {
                        ImageViewing(viewModel: .init(image: displayImage))
                    } else {
                        EmptyView()
                    }
                }
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
            viewModel.fileEnumerator.enumerateImages { images in
                self.images = images
            }
        })
        .onAppear {
            viewModel.fileEnumerator.enumerateImages { images in
                self.images = images
            }
        }.edgesIgnoringSafeArea(.all)
    }
}

struct GalleryView_Previews: PreviewProvider {
    private class DemoFileEnumerator: FileEnumerator {
        func loadMediaPreview(for media: ShadowPixMedia) {
            media.decryptedImage = DecryptedImage(image: UIImage(systemName: "photo.fill")!)
        }
        
        required init(directoryModel: DemoDirectoryModel) {
            
        }
        
        
        func enumerateImages(completion: ([ShadowPixMedia]) -> Void) {
            completion((0...10).map { _ in
                ShadowPixMedia(url: URL(fileURLWithPath: ""))
            })
            
        }
    }
    
    private class DemoDirectoryModel: DirectoryModel {
        required init(subdirectory: String = "", keyName: String = "") {
            
        }
        
        let subdirectory = ""
        let keyName = ""
        
        var driveURL: URL {
            URL(fileURLWithPath: "")
        }
    }

    static var previews: some View {
        GalleryView(viewModel: GalleryViewModel(fileEnumerator: DemoFileEnumerator(directoryModel: DemoDirectoryModel()))).environmentObject(ShadowPixState.shared)
    }
}
