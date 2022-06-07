//
//  GalleryView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI
import Combine

struct AsyncImage<Placeholder: View, T: MediaDescribing>: View where T.MediaSource == URL {
    
    class ViewModel: ObservableObject {
        private var loader: FileReader
        private var targetMedia: T
        private var cancellables = Set<AnyCancellable>()
        @Published var cleartextMedia: CleartextMedia<Data>?
        
        init(targetMedia: T, loader: FileReader) {
            self.targetMedia = targetMedia
            self.loader = loader
        }
        
        func loadPreview() {
            loader.loadMediaPreview(for: targetMedia).sink { completion in
                
            } receiveValue: { media in
                self.cleartextMedia = media
            }.store(in: &cancellables)
        }
    }
    
    private var placeholder: Placeholder
    @ObservedObject private var viewModel: ViewModel
    
    init(viewModel: ViewModel, placeholder: () -> Placeholder) {
        self.viewModel = viewModel
        self.placeholder = placeholder()
    }
    
    
    var body: some View {
        
        content.onAppear {
            viewModel.loadPreview()
        }
    }
    
    @ViewBuilder private var content: some View {
        // need separate view for holding preview
        if let decrypted = viewModel.cleartextMedia?.source, let image = UIImage(data: decrypted) {
            Image(uiImage: image)
                .resizable()
                .clipped()
                .aspectRatio(contentMode:.fit)
        } else {
            placeholder
        }
    }
}

class GalleryViewModel: ObservableObject {
    @Published var sourceDirectory: DirectoryModel
    var fileAccess: FileAccess
    init(sourceDirectory: DirectoryModel, fileAccess: FileAccess) {
        self.sourceDirectory = sourceDirectory
        self.fileAccess = fileAccess
    }
}

struct GalleryView: View {
    
    @State private var images: [EncryptedMedia] = []
    @State var displayImage: EncryptedMedia?
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
                    AsyncImage(viewModel: .init(targetMedia: image, loader: viewModel.fileAccess)) {
                        Color.gray
                    }.onTapGesture {
                        self.displayImage = image
                        self.isDisplayingImage = true
                    }
                }
                
            }.padding(.horizontal)
        }
        .onReceive(viewModel.$sourceDirectory, perform: { directory in
            viewModel.fileAccess.enumerateMedia(for: directory) { images in
                self.images = images
            }
        })
        .onAppear {
            viewModel.fileAccess.enumerateMedia(for: viewModel.sourceDirectory) { images in
                self.images = images
            }
        }.edgesIgnoringSafeArea(.all)
    }
}

struct GalleryView_Previews: PreviewProvider {
    
    static var previews: some View {
        let enumerator = DemoFileEnumerator(directoryModel: DemoDirectoryModel(), key: nil)
        GalleryView(viewModel: GalleryViewModel(sourceDirectory: DemoDirectoryModel(), fileAccess: DemoFileEnumerator()))
    }
}
