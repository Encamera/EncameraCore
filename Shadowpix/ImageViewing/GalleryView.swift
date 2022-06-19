//
//  GalleryView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI
import Combine

@MainActor
class GalleryViewModel: ObservableObject {
    
    var displayMedia: Binding<EncryptedMedia?>
    @Published var isDisplayingMedia: Bool = false
    @Published var media: [EncryptedMedia] = []
    var mediaTypeBinding: Binding<MediaType>
    var cancellables = Set<AnyCancellable>()
    var fileAccess: FileAccess
    var keyManager: KeyManager
    
    init(fileAccess: FileAccess, keyManager: KeyManager, mediaType: Binding<MediaType>, displayMedia: Binding<EncryptedMedia?>) {
        self.fileAccess = fileAccess
        self.keyManager = keyManager
        self.mediaTypeBinding = mediaType
        self.displayMedia = displayMedia
    }
    
    
    func enumerateMedia() async {
        self.media = await fileAccess.enumerateMedia(for: mediaTypeBinding.wrappedValue)
        print(self.media)
    }
}

struct GalleryItem: View {
    
    var fileAccess: FileAccess
    var keyManager: KeyManager
    var media: EncryptedMedia
    @State private var isActive: Bool = false
    
    var body: some View {
        NavigationLink(isActive: $isActive, destination: {
            switch media.mediaType {
            case .photo:
                ImageViewing(viewModel: ImageViewingViewModel<EncryptedMedia, DiskFileAccess<iCloudFilesDirectoryModel>> .init(media: media, keyManager: keyManager))
            case .video:
                MovieViewing<EncryptedMedia, DiskFileAccess<iCloudFilesDirectoryModel>>(viewModel: .init(media: media, keyManager: keyManager))
            default:
                EmptyView()
            }
        }, label: {
            AsyncImage(viewModel: .init(targetMedia: media, loader: fileAccess)) {
                ProgressView()
            }
            
            .clipped()	
            .aspectRatio(1, contentMode: .fill)
            
        }).onTapGesture {
            isActive = true
        }
    }
}

struct GalleryView: View {
    
    @ObservedObject var viewModel: GalleryViewModel
    
    var body: some View {
        let item = viewModel.isDisplayingMedia ? GridItem(.flexible(minimum: 200)) : GridItem(.adaptive(minimum: 150))
        let gridItems = [
            GridItem(.adaptive(minimum: 150))
        ]
        ScrollView {
            LazyVGrid(columns: gridItems, spacing: 0) {
                ForEach(viewModel.media, id: \.id) { mediaItem in
                    GalleryItem(fileAccess: viewModel.fileAccess, keyManager: viewModel.keyManager, media: mediaItem)
                }
            }
        }
        .task(id: viewModel.mediaTypeBinding.wrappedValue) {
            await viewModel.enumerateMedia()
        }
        .task {
            await viewModel.enumerateMedia()
        }
        .edgesIgnoringSafeArea(.all)
        
    }
}

//struct GalleryView_Previews: PreviewProvider {
//
//    static var previews: some View {
//
//        GalleryView(viewModel: GalleryViewModel(fileAccess: DemoFileEnumerator(), keyManager: KeychainKeyManager(isAuthorized: Just(true).eraseToAnyPublisher()), mediaType: .constant(.photo)))
//    }
//}
