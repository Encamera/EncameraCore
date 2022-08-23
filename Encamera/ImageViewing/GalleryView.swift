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
    
    @ObservedObject var viewModel: GalleryViewModel
    @State var showingCarousel = false
    @State var carouselTarget: EncryptedMedia? {
        didSet {
            if carouselTarget == nil {
                showingCarousel = false
            } else {
                showingCarousel = true
            }
        }
    }
    
    @State var shouldClose: Bool = false

    
    var body: some View {
        let _ = Self._printChanges()

        let gridItems = [
            GridItem(.adaptive(minimum: 100), spacing: 1)
        ]
        ZStack {
            
            ScrollView {
                LazyVGrid(columns: gridItems, spacing: 1) {
                    ForEach(viewModel.media, id: \.gridID) { mediaItem in
                        
                        GalleryItem(fileAccess: viewModel.fileAccess, media: mediaItem, galleryViewModel: viewModel)
                            .onTapGesture {
                                carouselTarget = mediaItem
                            }
                    }
                }
            }
            if let carouselTarget = carouselTarget, showingCarousel == true {
                GalleryHorizontalScrollView(viewModel: .init(media: viewModel.media, selectedMedia: carouselTarget, fileAccess: viewModel.fileAccess), shouldShow: $showingCarousel)
            }
        }
        .task {
            await viewModel.enumerateMedia()
        }.background(Color.black)
//        .edgesIgnoringSafeArea(.all)
        
    }
}

struct GalleryView_Previews: PreviewProvider {

    static var previews: some View {

        GalleryView(viewModel: GalleryViewModel(fileAccess: DemoFileEnumerator(), keyManager: MultipleKeyKeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager())))
    }
}
