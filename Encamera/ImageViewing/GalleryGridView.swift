//
//  GalleryView.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI
import Combine


@MainActor
class GalleryGridViewModel: ObservableObject {
    
    var privateKey: PrivateKey
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
    var storageSetting = DataStorageUserDefaultsSetting()
    
    init(privateKey: PrivateKey) {
        
        self.privateKey = privateKey
        self.fileAccess = DiskFileAccess()
    }
    
    
    func enumerateMedia() async {
        await fileAccess.configure(with: privateKey, storageSettingsManager: storageSetting)
        let enumerated: [EncryptedMedia] = await fileAccess.enumerateMedia()
        media = enumerated
    }
}

struct GalleryGridView: View {
    
    @StateObject var viewModel: GalleryGridViewModel
    
    var body: some View {
        let gridItems = [
            GridItem(.adaptive(minimum: 100), spacing: 1)
        ]
        ZStack {
            ScrollView {
                HStack {
                    Text("\(viewModel.media.count) image\(viewModel.media.count == 1 ? "" : "s")")
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        LocalDeeplinkingUtils.openKeyContentsInFiles(keyName: viewModel.privateKey.name)
                    } label: {
                        Image(systemName: "folder")
                    }
                    

                }.padding()
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
        .screenBlocked()
        .navigationTitle(viewModel.privateKey.name)
        
    }
}

struct GalleryView_Previews: PreviewProvider {
    
    static var previews: some View {
        NavigationView {
            GalleryGridView(viewModel: GalleryGridViewModel(privateKey: DemoPrivateKey.dummyKey()))
        }
    }
}
