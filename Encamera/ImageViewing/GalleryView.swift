//
//  GalleryView.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI
import Combine


@MainActor
class GalleryViewModel: ObservableObject {
    
    @Published var isDisplayingMedia: Bool = false
    @Published var media: [EncryptedMedia] = []
    @Published var showingCarousel = false
    @Published var carouselTarget: EncryptedMedia? {
        didSet {
            if carouselTarget == nil {
                showingCarousel = false
            } else {
                showingCarousel = true
            }
        }
    }
    var cancellables = Set<AnyCancellable>()
    var fileAccess: FileAccess
    var keyManager: KeyManager
    
    init(fileAccess: FileAccess, keyManager: KeyManager) {
        self.fileAccess = fileAccess
        self.keyManager = keyManager
    }
    
    
    func enumerateMedia() async {
        let enumerated: [EncryptedMedia] = await fileAccess.enumerateMedia()
        media = enumerated
    }
}

struct GalleryView: View {
    
    @StateObject var viewModel: GalleryViewModel
    
    var body: some View {
        let gridItems = [
            GridItem(.adaptive(minimum: 100), spacing: 1)
        ]
        ZStack {
            
            ScrollView {
                LazyVGrid(columns: gridItems, spacing: 1) {
                    ForEach(viewModel.media, id: \.gridID) { mediaItem in
                        
                        GalleryItem(fileAccess: viewModel.fileAccess, media: mediaItem)
                            .onTapGesture {
                                viewModel.carouselTarget = mediaItem
                            }
                    }
                }
            }
            

            NavigationLink(isActive: $viewModel.showingCarousel) {
                if let carouselTarget = viewModel.carouselTarget, viewModel.showingCarousel == true {
                    
                    GalleryHorizontalScrollView(
                        viewModel: .init(media: viewModel.media, selectedMedia: carouselTarget, fileAccess: viewModel.fileAccess))
                }
            } label: {
                EmptyView()
            }
            
        }
        .task {
            await viewModel.enumerateMedia()
        }
        .background(Color.black)
        
    }
}

struct GalleryView_Previews: PreviewProvider {

    static var previews: some View {

        GalleryView(viewModel: GalleryViewModel(fileAccess: DemoFileEnumerator(), keyManager: MultipleKeyKeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager())))
    }
}
