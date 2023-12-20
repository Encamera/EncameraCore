//
//  AlbumGrid.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import Combine
import EncameraCore
import SwiftUI

class AlbumGridViewModel: ObservableObject {
    @Published var albums: [Album] = .init()
    @Published var isShowingAddExistingKeyView: Bool = false
    @Published var isKeyTutorialClosed: Bool = true
    @Published var isShowingNotificationBanner: Bool = false
    @Published var isShowingStoreView: Bool = false

    var albumManager: AlbumManaging
    var fileManager: FileAccess
    var key: PrivateKey

    var purchaseManager: PurchasedPermissionManaging

    private var cancellables = Set<AnyCancellable>()

    init(key: PrivateKey, purchaseManager: PurchasedPermissionManaging, fileManager: FileAccess, albumManger: AlbumManaging) {
        self.purchaseManager = purchaseManager
        self.fileManager = fileManager
        self.albumManager = albumManger
        self.key = key
        setAlbums()
        self.isKeyTutorialClosed = UserDefaultUtils.bool(forKey: .keyTutorialClosed)
        albumManger.albumOperationPublisher
            .receive(on: RunLoop.main)
            .sink { _ in
            self.setAlbums()
        }.store(in: &cancellables)
        albumManager.loadAlbumsFromFilesystem()
        FileOperationBus.shared.operations
            .receive(on: RunLoop.main)
            .sink { operation in
            self.albumManager.loadAlbumsFromFilesystem()
            self.setAlbums()
        }.store(in: &cancellables)
        albumManger.albumOperationPublisher
            .receive(on: RunLoop.main)
            .sink { operation in
                guard case .albumMoved(album: _) = operation else {
                    return
                }
                self.albumManager.loadAlbumsFromFilesystem()
                self.setAlbums()
            }.store(in: &cancellables)
        self.isShowingNotificationBanner = showNotificationBannerDefault
    }

    func setAlbums() {
        UserDefaultUtils.set(true, forKey: .hasOpenedAlbum)
        albums = Array(albumManager.albums)
    }

    @MainActor
    var shouldShowPurchaseScreenForKeys: Bool {
        if albums.count == 0 {
            return false
        }

        return purchaseManager.isAllowedAccess(feature: .createKey(count: .infinity)) == false
    }

    var showNotificationBellIndicator: Bool {
        UserDefaultUtils.integer(forKey: .launchCount) < 5
    }

    var showNotificationBannerDefault: Bool {
        UserDefaultUtils.integer(forKey: .launchCount) < 3
    }

}

struct AlbumGrid: View {
    @StateObject var viewModel: AlbumGridViewModel


    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(L10n.albumsTitle)
                    .fontType(.large, weight: .bold)
                Spacer()
                NotificationBell(showIndicator: viewModel.showNotificationBellIndicator) {
                    EventTracking.trackNotificationBellPressed()
                    withAnimation {
                        viewModel.isShowingNotificationBanner.toggle()
                    }
                }
            }
            .padding(24)
            NotificationCarousel(isPresented: $viewModel.isShowingNotificationBanner)
            GeometryReader { geo in
                let frame = geo.frame(in: .local)
                let spacing = CGFloat(17.0)
                let side = CGFloat(CGFloat(frame.width / 2) - spacing)
                let columns = [
                    GridItem(.fixed(side), spacing: spacing),
                    GridItem(.fixed(side))
                ]
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        Group {
                            createAlbumButton(side: side)
                            albums(side: side)

                        }.frame(height: side + 60)
                    }
                    .padding(.bottom, 80)
                }


                .screenBlocked()
            }
            .onAppear {
                viewModel.setAlbums()
            }
            .padding(24)
            .toolbar(.hidden)
        }
        .productStore(isPresented: $viewModel.isShowingStoreView, fromViewName: "AlbumGrid")
    }

    @ViewBuilder
    private func createAlbumButton(side: CGFloat) -> some View {
        let button = AlbumBaseGridItem(image: Image("Albums-Add"), title: L10n.createNewAlbum, subheading: nil, width: side, strokeStyle: StrokeStyle(lineWidth: 2, dash: [6], dashPhase: 0.0), shouldResizeImage: false)
        if !viewModel.shouldShowPurchaseScreenForKeys {
            NavigationLink(value: "CreateAlbum") {
                button
            }
        } else {
            Button {
                viewModel.isShowingStoreView = true
            } label: {
                button
            }

        }
    }

    @ViewBuilder
    private func albums(side: CGFloat) -> some View {
        ForEach(Array(viewModel.albums), id: \.id) { album in
            NavigationLink(value: album) {
                AlbumGridItem(key: album.key,
                              album: album,
                              albumManager: viewModel.albumManager,
                              width: side)
            }
        }
    }

}

#Preview {
    AlbumGrid(viewModel: .init(key: DemoPrivateKey.dummyKey(),
                               purchaseManager: DemoPurchasedPermissionManaging(),
                               fileManager: DemoFileEnumerator(),
                               albumManger: DemoAlbumManager()))
    .gradientBackground()
}
