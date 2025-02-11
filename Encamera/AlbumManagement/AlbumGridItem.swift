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

    var fileReader: FileReader
    var album: Album
    var albumManager: AlbumManaging
    private var cancellables = Set<AnyCancellable>()

    @Published var countOfMedia: Int = 0
    @Published var leadingImage: UIImage?

    init(album: Album, fileReader: FileReader, albumManager: AlbumManaging) {
        self.album = album
        Task {
            await fileReader.configure(
                for: album,
                albumManager: albumManager
            )

        }
        self.fileReader = fileReader
        self.albumManager = albumManager
        self.countOfMedia = albumManager.albumMediaCount(album: album)
        FileOperationBus.shared
            .operations
            .sink { operation in
                Task {
                    try await self.load()
                }
        }.store(in: &cancellables)

    }

    func load() async throws {
        do {
            let thumb = try await fileReader.loadLeadingThumbnail()
            await MainActor.run {
                self.countOfMedia = albumManager.albumMediaCount(album: album)
                self.leadingImage = thumb
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

    init(album: Album, albumManager: AlbumManaging, width: CGFloat, fileReader: FileAccess) {
        albumName = album.name
        _viewModel = StateObject(wrappedValue: AlbumGridItemModel(album: album, fileReader: fileReader, albumManager: albumManager))
        self.width = width
    }

    var body: some View {
        AlbumBaseGridItem(uiImage: viewModel.leadingImage,
                          title: albumName,
                          subheading: L10n.imageS(viewModel.countOfMedia),
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
