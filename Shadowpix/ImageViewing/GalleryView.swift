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
    @ObservedObject private var image: ShadowPixMedia
    
    init(_ image: ShadowPixMedia, placeholder: () -> Placeholder) {
        self.placeholder = placeholder()
        self.image = image
    }
    
    var body: some View {
        
        content.onAppear {
            image.loadImage()
        }
    }
    
    private var content: some View {
        Group {
            if let decrypted = image.decryptedImage?.image {
                Image(uiImage: decrypted)
                    .resizable()
                    .clipped()
                    .background(Color.orange)
                    .aspectRatio(contentMode:.fit)
            } else {
                placeholder
            }
        }
    }
}

struct GalleryView: View {
    
    @EnvironmentObject var state: ShadowPixState
    @State var images: [ShadowPixMedia] = []
    @State var displayImage: ShadowPixMedia?
    @State var isDisplayingImage: Bool = false
    var body: some View {
        let gridItems = [
            GridItem(.adaptive(minimum: 100))
        ]
        NavigationView {
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
                        AsyncImage(image) {
                            Color.gray.frame(width: 50, height: 50)
                        }.onTapGesture {
                            self.displayImage = image
                            self.isDisplayingImage = true
                        }
                    }
                    
                }.padding(.horizontal)
            }.navigationTitle(state.selectedKey?.name ?? "No Key")
        }
        .onAppear {
            guard let key = ShadowPixState.shared.selectedKey else {
                return
            }
            iCloudFilesManager.enumerateImagesFor(key: key) { images in
                self.images = images
            }
        }
    }
}

struct GalleryView_Previews: PreviewProvider {
    static var items: [ShadowPixMedia] {
        return (0...10).map { item in
            let id = "\(item)"
//            let image = DecryptedImage(image: UIImage(systemName: "lock")!)
            let media = ShadowPixMedia(url: URL(string: id)!)
            
            return media
        }
    }
    static var previews: some View {
//        Color.orange
        GalleryView(images: items).environmentObject(ShadowPixState.shared)
    }
}
