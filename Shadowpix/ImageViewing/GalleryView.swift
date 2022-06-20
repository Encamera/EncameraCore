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
    
    @Published var isDisplayingMedia: Bool = false
    @Published var media: [EncryptedMedia] = []
    var mediaTypeBinding: Binding<MediaType>
    var cancellables = Set<AnyCancellable>()
    var fileAccess: FileAccess
    var keyManager: KeyManager
    
    init(fileAccess: FileAccess, keyManager: KeyManager, mediaType: Binding<MediaType>) {
        self.fileAccess = fileAccess
        self.keyManager = keyManager
        self.mediaTypeBinding = mediaType
    }
    
    
    func enumerateMedia() async {
        self.media = await fileAccess.enumerateMedia(for: mediaTypeBinding.wrappedValue)
    }
}

struct GalleryView: View {
    
    @ObservedObject var viewModel: GalleryViewModel
    
    var body: some View {
        let gridItems = [
            GridItem(.adaptive(minimum: 100), spacing: 1)
        ]
        ScrollView {
            let _ = Self._printChanges()
            LazyVGrid(columns: gridItems, spacing: 1) {
                ForEach(viewModel.media, id: \.id) { mediaItem in
                    GalleryItem(fileAccess: viewModel.fileAccess, keyManager: viewModel.keyManager, media: mediaItem)
                }
            }
        }
        .task(id: viewModel.mediaTypeBinding.wrappedValue) {
            await viewModel.enumerateMedia()
        }
        .edgesIgnoringSafeArea(.all)
        
    }
}

struct GalleryView_Previews: PreviewProvider {

    static var previews: some View {

        GalleryView(viewModel: GalleryViewModel(fileAccess: DemoFileEnumerator(), keyManager: KeychainKeyManager(isAuthorized: Just(true).eraseToAnyPublisher()), mediaType: .constant(.photo)))
    }
}
