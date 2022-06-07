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

    @Published var displayMedia: EncryptedMedia?
    @Published var isDisplayingMedia: Bool = false
    @Published var images: [EncryptedMedia] = []
    
    var fileAccess: FileAccess
    var keyManager: KeyManager
    
    init(sourceDirectory: DirectoryModel, fileAccess: FileAccess, keyManager: KeyManager) {
        self.sourceDirectory = sourceDirectory
        self.fileAccess = fileAccess
        self.keyManager = keyManager
    }
    
    func enumerateMedia() {
        fileAccess.enumerateMedia(for: sourceDirectory) { images in
            self.images = images
        }
    }
}

struct GalleryView: View {
    
    @ObservedObject var viewModel: GalleryViewModel
    
    
    var body: some View {
        let gridItems = [
            GridItem(.adaptive(minimum: 100))
        ]
        ScrollView {
            
            NavigationLink("", isActive: $viewModel.isDisplayingMedia, destination: {
                if let media = viewModel.displayMedia {
                    if media.mediaType == .photo {
                        ImageViewing(viewModel: ImageViewingViewModel<EncryptedMedia, iCloudFilesEnumerator> .init(image: media, keyManager: viewModel.keyManager))
                    } else {
                        EmptyView()
                    }
                } else {
                    EmptyView()
                }
                
            })
            LazyVGrid(columns: gridItems, spacing: 1) {
                ForEach(viewModel.images, id: \.id) { image in
                    AsyncImage(viewModel: .init(targetMedia: image, loader: viewModel.fileAccess)) {
                        Color.gray
                    }.onTapGesture {
                        self.viewModel.displayMedia = image
                        self.viewModel.isDisplayingMedia = true
                    }
                }
                
            }.padding(.horizontal)
        }
        .onReceive(viewModel.$sourceDirectory, perform: { directory in
            viewModel.enumerateMedia()
        })
        .onAppear {
            viewModel.enumerateMedia()
        }.edgesIgnoringSafeArea(.all)
    }
}

struct GalleryView_Previews: PreviewProvider {
    
    static var previews: some View {
        let enumerator = DemoFileEnumerator(directoryModel: DemoDirectoryModel(), key: nil)
        GalleryView(viewModel: GalleryViewModel(sourceDirectory: DemoDirectoryModel(), fileAccess: DemoFileEnumerator(), keyManager: KeychainKeyManager(isAuthorized: Just(true).eraseToAnyPublisher())))
    }
}
