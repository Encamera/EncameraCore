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
    var purchasedPermissions: PurchasedPermissionManaging?

    private var cancellables = Set<AnyCancellable>()

    @Published var countOfMedia: Int = 0
    @Published var leadingImage: UIImage?
    @Published var storageIconName: String?
    @Published var blurEnabled: Bool

    init(album: Album, fileReader: FileReader, albumManager: AlbumManaging, blurEnabled: Bool, purchasedPermissions: PurchasedPermissionManaging? = nil) {
        self.album = album
        Task {
            await fileReader.configure(
                for: album,
                albumManager: albumManager
            )

        }
        self.blurEnabled = blurEnabled
        self.fileReader = fileReader
        self.albumManager = albumManager
        self.purchasedPermissions = purchasedPermissions
        self.countOfMedia = albumManager.albumMediaCount(album: album)
        // Determine the icon name based on storage option
        switch album.storageOption {
        case .icloud:
            self.storageIconName = "icloud"
        case .local:
            self.storageIconName = "iphone"
        // Add default or handle other cases if necessary
        }
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
            let thumb = try await fileReader.loadLeadingThumbnail(purchasedPermissions: purchasedPermissions)
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

    // Define a computed property for the subheading view
    @ViewBuilder
    private var subheadingView: some View {
        HStack(spacing: 4) { // Use HStack to place items side-by-side
            Text(L10n.imageS(viewModel.countOfMedia))
            if let iconName = viewModel.storageIconName {
                Image(systemName: iconName)
                    .imageScale(.small) // Adjust scale as needed
            }
        }
    }

    init(album: Album, albumManager: AlbumManaging, width: CGFloat, fileReader: FileAccess, blurEnabled: Bool, purchasedPermissions: PurchasedPermissionManaging? = nil) {
        albumName = album.name
        _viewModel = StateObject(wrappedValue: AlbumGridItemModel(album: album, fileReader: fileReader, albumManager: albumManager, blurEnabled: blurEnabled, purchasedPermissions: purchasedPermissions))
        self.width = width
    }

    var body: some View {
        AlbumBaseGridItem(uiImage: viewModel.leadingImage,
                          title: albumName,
                          subheadingView: { subheadingView }, // Wrap in a closure
                          width: width,
                          blurEnabled: viewModel.blurEnabled)
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
