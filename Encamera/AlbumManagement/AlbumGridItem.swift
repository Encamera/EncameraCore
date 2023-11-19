//
//  AlbumGridItem.swift
//  Encamera
//
//  Created by Alexander Freas on 28.11.22.
//

import SwiftUI
import Combine
import EncameraCore

class AlbumGridItemModel: ObservableObject {
    
    var fileReader: FileReader = DiskFileAccess()
    var album: Album
    var albumManager: AlbumManaging = AlbumManager()
    var storageModel: DataStorageModel?
    var storageType: StorageType? {
        storageModel?.storageType
    }
    
    @Published var countOfMedia: Int = 0
    @Published var imageCount: Int?
    @Published var leadingImage: UIImage?

    init(album: Album, key: PrivateKey) {
        self.album = album
        Task {
            await fileReader.configure(
                for: album,
                with: key,
                albumManager: albumManager
            )
            
        }
        storageModel = albumManager.storageModel(for: album)
        self.countOfMedia = storageModel?.countOfFiles(matchingFileExtension: [MediaType.photo.fileExtension, MediaType.video.fileExtension]) ?? 0

    }

    func load() async throws {
        
        do {
            let thumb = try await fileReader.loadLeadingThumbnail()
            await MainActor.run {
                self.imageCount = countOfMedia
                if let thumb {
                    self.leadingImage = thumb
                }
            }
        } catch {
            debugPrint("Error in load function: \(error)")
        }
    }
}

struct AlbumGridItem: View {

    @StateObject var viewModel: AlbumGridItemModel
    var albumName: String
    var width: CGFloat

    init(key: PrivateKey, album: Album, width: CGFloat) {
        albumName = album.name
        _viewModel = StateObject(wrappedValue: AlbumGridItemModel(album: album, key: key))
        self.width = width
    }

    var body: some View {
        
        AlbumBaseGridItem(uiImage: viewModel.leadingImage,
                          title: albumName,
                          subheading: viewModel.imageCount != nil ? L10n.imageS(viewModel.imageCount!) : nil,
                          width: width)
            .task {

                try? await viewModel.load()
            }
    }
}




//struct AlbumGridItem_Previews: PreviewProvider {
//    static var previews: some View {
//        
//        AlbumGrid(viewModel: .init(keyManager: DemoKeyManager(keys: [            DemoPrivateKey.dummyKey(name: "cats and their people"),
//                                                         DemoPrivateKey.dummyKey(name: "dogs"),
//                                                         DemoPrivateKey.dummyKey(name: "rats"),
//                                                         DemoPrivateKey.dummyKey(name: "mice"),
//                                                         DemoPrivateKey.dummyKey(name: "cows"),
//                                                         DemoPrivateKey.dummyKey(name: "very very very very very very long name that could overflow"),
//                                                                           ]), purchaseManager: AppPurchasedPermissionUtils(), fileManager: DemoFileEnumerator()))
//        .preferredColorScheme(.dark)
//    }
//        
//}
