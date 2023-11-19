//
//  AlbumGrid.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import SwiftUI
import EncameraCore
import Combine

class AlbumGridViewModel: ObservableObject {
    @Published var albums: [Album] = []
    var albumManager: AlbumManaging
    var fileManager: FileAccess
    var key: PrivateKey
    @Published var isShowingAddExistingKeyView: Bool = false
    @Published var isKeyTutorialClosed: Bool = true
    var purchaseManager: PurchasedPermissionManaging

    private var cancellables = Set<AnyCancellable>()

    init(key: PrivateKey, purchaseManager: PurchasedPermissionManaging, fileManager: FileAccess, albumManger: AlbumManaging) {
        self.purchaseManager = purchaseManager
        self.fileManager = fileManager
        self.albumManager = albumManger
        self.key = key
        loadAlbums()
        self.isKeyTutorialClosed = UserDefaultUtils.bool(forKey: .keyTutorialClosed)
        albumManger.albumPublisher.sink { _ in
            self.loadAlbums()
        }.store(in: &cancellables)
    }

    func loadAlbums() {
        UserDefaultUtils.set(true, forKey: .hasOpenedAlbum)
        self.albums = self.albumManager.availableAlbums
    }

    @MainActor
    var shouldShowPurchaseScreenForKeys: Bool {

        if self.albums.count == 0 {
            return false
        }

        return purchaseManager.isAllowedAccess(feature: .createKey(count: .infinity)) == false
    }

}


struct AlbumGrid: View {


    @StateObject var viewModel: AlbumGridViewModel


    var body: some View {
        VStack(alignment: .leading) {
            Text(L10n.albumsTitle)
                .fontType(.large, weight: .bold)

            GeometryReader { geo in
                let frame = geo.frame(in: .local)
                let spacing = 17.0
                let side = frame.width/2 - spacing
                let columns = [
                    GridItem(.fixed(side), spacing: spacing),
                    GridItem(.fixed(side))
                ]
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        Group {

                            NavigationLink {
                                if viewModel.shouldShowPurchaseScreenForKeys {
                                    ProductStoreView(showDismissButton: false)
                                } else {
                                    CreateAlbum(viewModel: .init(albumManager: viewModel.albumManager))
                                }
                            } label: {
                                AlbumBaseGridItem(image: Image("Albums-Add"), title: L10n.createNewAlbum, subheading: nil, width: side, strokeStyle: StrokeStyle(lineWidth: 2, dash: [10], dashPhase: 0.0), shouldResizeImage: false)
                            }


                            albums(side: side)

                        }.frame(height: side + 60)
                    }
                    .padding(.bottom, 80)
                }

                .screenBlocked()
            }
            .onAppear {
                viewModel.loadAlbums()
            }
            .navigationBarTitle(L10n.myKeys)
        }
        .padding(24)
    }

    @ViewBuilder
    private func albums(side: CGFloat) -> some View {

        ForEach(viewModel.albums, id: \.id) { album in
            NavigationLink {
                AlbumDetailView(viewModel: .init(albumManager: viewModel.albumManager, key: viewModel.key, album: album))
            } label: {
                AlbumGridItem(key: viewModel.key, album: album, width: side)
            }
        }
    }

}
//#Preview {
//    AlbumGrid(viewModel: .init(keyManager: DemoKeyManager(keys: [            DemoPrivateKey.dummyKey(name: "cats and their people"),
//                                                                             DemoPrivateKey.dummyKey(name: "dogs"),
//                                                                             DemoPrivateKey.dummyKey(name: "rats"),
//                                                                             DemoPrivateKey.dummyKey(name: "mice"),
//                                                                             DemoPrivateKey.dummyKey(name: "cows"),
//                                                                             DemoPrivateKey.dummyKey(name: "very very very very very very long name that could overflow"),
//                                                                ]), purchaseManager: AppPurchasedPermissionUtils(), fileManager: DemoFileEnumerator()))
//}
