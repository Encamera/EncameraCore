//
//  AlbumGrid.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import Combine
import EncameraCore
import SwiftUI

private enum Constants {

    static let numberOfAlbumsWide: Int = {
        let device = UIDevice.current
        let orientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .unknown

        switch device.userInterfaceIdiom {
        case .pad:
            return orientation.isLandscape ? 4 : 3
        case .phone:
            return orientation.isLandscape ? 3 : 2
        default:
            return 2
        }
    }()

    static func numberOfAlbumsWide(for size: CGSize) -> Int {
            let device = UIDevice.current
            let width = size.width

            switch device.userInterfaceIdiom {
            case .pad:
                return width > 800 ? 4 : 3  // iPads: 4 columns for wide screens, 3 for narrow screens
            case .phone:
                return width > 600 ? 3 : 2  // iPhones: 3 columns for wide screens, 2 for narrow screens
            default:
                return 2
            }
        }
}



class AlbumGridViewModel<D: FileAccess>: ObservableObject {
    @Published var albums: [Album] = .init()
    @Published var isShowingAddExistingKeyView: Bool = false
    @Published var isKeyTutorialClosed: Bool = true
    @Published var isShowingStoreView: Bool = false

    var albumManager: AlbumManaging
    var fileManager: D

    var purchaseManager: PurchasedPermissionManaging

    private var cancellables = Set<AnyCancellable>()

    init(purchaseManager: PurchasedPermissionManaging, fileManager: D, albumManger: AlbumManaging) {
        self.purchaseManager = purchaseManager
        self.fileManager = fileManager
        self.albumManager = albumManger
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
        LaunchCountUtils.fetchCurrentVersionLaunchCount() < 5
    }

    var showNotificationBannerDefault: Bool {
        LaunchCountUtils.fetchCurrentVersionLaunchCount() < 3
    }

}

struct AlbumGrid<D: FileAccess>: View {
    @StateObject var viewModel: AlbumGridViewModel<D>
    @State var path: NavigationPath = .init()
    @State private var showNotificationSheet: Bool = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    var body: some View {
        let spacing = CGFloat(17.0)

        VStack(alignment: .leading) {
            ViewHeader(title: "Encamera", rightContent: {
                Button {
                    showNotificationSheet = true
                    EventTracking.trackNotificationBellPressed()
                } label: {
                    NotificationBell(showIndicator: viewModel.showNotificationBellIndicator)
                }
            })

            GeometryReader { geo in
                let frame = geo.frame(in: .local)
                let numberOfColumns = Constants.numberOfAlbumsWide(for: frame.size)
                let side = ((frame.width - CGFloat(numberOfColumns + 1) * spacing) / CGFloat(numberOfColumns))
                let columns = Array(repeating: GridItem(.fixed(side), spacing: spacing), count: numberOfColumns)

                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        Group {
                            createAlbumButton(side: side)
                            albums(side: side)
                        }
                        .frame(height: side + 60)
                    }
                    .padding(.bottom, 120)
                }
                .screenBlocked()
            }
            .onAppear {
                viewModel.setAlbums()
            }
            .padding([.leading, .trailing], Spacing.pt24.value - spacing / 2)
            .padding([.top, .bottom], Spacing.pt16.value)
            .toolbar(.hidden)
        }
        .fullScreenCover(isPresented: $showNotificationSheet) {
            NotificationList {
                showNotificationSheet = false
            }
        }
        .productStore(isPresented: $viewModel.isShowingStoreView, fromViewName: "AlbumGrid")
    }



    @ViewBuilder
    private func createAlbumButton(side: CGFloat) -> some View {
        let button = AlbumBaseGridItem(image: Image("Albums-Add"), title: L10n.createNewAlbum, subheading: nil, width: side, strokeStyle: StrokeStyle(lineWidth: 2, dash: [6], dashPhase: 0.0), shouldResizeImage: false)
        if !viewModel.shouldShowPurchaseScreenForKeys {
            NavigationLink(value: AppNavigationPaths.createAlbum) {
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
            NavigationLink(value: AppNavigationPaths.albumDetail(album: album)) {
                AlbumGridItem(album: album,
                              albumManager: viewModel.albumManager,
                              width: side, fileReader: D.init())
            }
        }
    }

}

#Preview {
    NavigationStack {
        AlbumGrid(viewModel: .init(purchaseManager: DemoPurchasedPermissionManaging(),
                                   fileManager: DemoFileEnumerator(),
                                   albumManger: DemoAlbumManager()))
        .gradientBackground()
    }
}
