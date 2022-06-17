//
//  GalleryView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI
import Combine

struct AsyncImage<Placeholder: View, T: MediaDescribing>: View {
    
    class ViewModel: ObservableObject {
        private var loader: FileReader
        private var targetMedia: T
        private var cancellables = Set<AnyCancellable>()
        @Published var cleartextMedia: CleartextMedia<Data>?
        
        init(targetMedia: T, loader: FileReader) {
            self.targetMedia = targetMedia
            self.loader = loader
        }
        
        func loadPreview() async {
            do {
                cleartextMedia = try await loader.loadMediaInMemory(media: targetMedia)
            } catch {
                print(error)
            }
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
            Task {
                await viewModel.loadPreview()
            }
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
    @Published var media: [CleartextMedia<Data>] = []
    
    var fileAccess: FileAccess
    var keyManager: KeyManager
    
    init(sourceDirectory: DirectoryModel, fileAccess: FileAccess, keyManager: KeyManager) {
        self.sourceDirectory = sourceDirectory
        self.fileAccess = fileAccess
        self.keyManager = keyManager
    }
    
    func enumerateMedia() async {
        Task {
            
            self.media = try await self.fileAccess.loadThumbnails(for: self.sourceDirectory)
        }
        
    }
    
    func loadThumbnailFor(media: EncryptedMedia) async throws -> CleartextMedia<Data> {
        let thumb = try await fileAccess.loadMediaPreview(for: media)
        return thumb
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
                        ImageViewing(viewModel: ImageViewingViewModel<EncryptedMedia, DiskFileAccess<iCloudFilesDirectoryModel>> .init(media: media, keyManager: viewModel.keyManager))
                    } else {
                        EmptyView()
                    }
                } else {
                    EmptyView()
                }
                
            })
            LazyVGrid(columns: gridItems, spacing: 1) {
                ForEach(viewModel.media, id: \.id) { image in
                    thumbFor(media: image)
                }
            }.padding(.horizontal)
        }
        .onReceive(viewModel.$sourceDirectory, perform: { directory in
            Task {
                await viewModel.enumerateMedia()
            }
        })
        .onAppear {
            Task {
                await viewModel.enumerateMedia()
            }
        }.edgesIgnoringSafeArea(.all)
    }
}

struct GalleryView_Previews: PreviewProvider {
    
    static var previews: some View {
        let enumerator = DemoFileEnumerator(directoryModel: DemoDirectoryModel(), key: nil)
        GalleryView(viewModel: GalleryViewModel(sourceDirectory: DemoDirectoryModel(), fileAccess: DemoFileEnumerator(), keyManager: KeychainKeyManager(isAuthorized: Just(true).eraseToAnyPublisher())))
    }
}
