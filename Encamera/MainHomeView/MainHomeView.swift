//
//  MainHomeView.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import SwiftUI
import EncameraCore
import AVFoundation
import Combine

class MainHomeViewViewModel<D: FileAccess>: ObservableObject {

    @Published var cameraMode: CameraMode = .photo
    @Published var rotationFromOrientation: CGFloat = 0.0
    @Published var showScreenBlocker: Bool = true
    @Published var isAuthenticated = false
    @Published var hasMediaToImport = false
    @Published var showImportedMediaScreen = false
    @Published var shouldShowTweetScreen: Bool = false
    @Published var selectedPath: NavigationPath = .init()
    @Published var selectedNavigationItem: BottomNavigationBar.ButtonItem = .albums
    var fileAccess: D
    var cameraService: CameraConfigurationService
    var keyManager: KeyManager
    var albumManager: AlbumManaging
    var cameraModel: CameraModel
    var purchasedPermissions: PurchasedPermissionManaging
    var settingsManager: SettingsManager
    private(set) var authManager: AuthManager
    private var cancellables = Set<AnyCancellable>()

    init(fileAccess: D,
         keyManager: KeyManager,
         albumManager: AlbumManaging,
         purchasedPermissions: PurchasedPermissionManaging,
         settingsManager: SettingsManager,
         authManager: AuthManager,
         cameraService: CameraConfigurationService
    ) {
        self.fileAccess = fileAccess
        self.keyManager = keyManager
        self.albumManager = albumManager
        self.purchasedPermissions = purchasedPermissions
        self.settingsManager = settingsManager
        self.authManager = authManager
        self.settingsManager = SettingsManager()
        self.cameraService = cameraService
        self.authManager = authManager
        self.cameraModel = .init(
            albumManager: albumManager,
            cameraService: cameraService,
            fileAccess: fileAccess,
            purchaseManager: purchasedPermissions
        )
    }

    func popLastView() {
        if !selectedPath.isEmpty {
            selectedPath.removeLast()
        }
    }

    func navigateToAlbumDetailView(with album: Album) {
        // Append the album to the navigation path
        selectedPath.append(album)
    }
}


struct MainHomeView<D: FileAccess>: View {

    @StateObject var viewModel: MainHomeViewViewModel<D>
    @Binding var showCamera: Bool
    
    @State private var selectedNavigationItem: BottomNavigationBar.ButtonItem = .albums {
        didSet {
            showCamera = false
        }
    }

    init(viewModel: MainHomeViewViewModel<D>, showCamera: Binding<Bool>) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _showCamera = showCamera
    }

    var body: some View {
        NavigationStack(path: $viewModel.selectedPath) {
            ZStack(alignment: .bottom) {
                if selectedNavigationItem == .camera || showCamera {
                    CameraView(cameraModel: viewModel.cameraModel, hasMediaToImport: $viewModel.hasMediaToImport, closeButtonTapped:{ targetAlbum in
                        UserDefaultUtils.set(false, forKey: .showCurrentAlbumOnLaunch)
                        if let targetAlbum {
                            viewModel.navigateToAlbumDetailView(with: targetAlbum)
                        }
                        withAnimation {
                            selectedNavigationItem = .albums
                        }
                    })
                    .transition(.opacity)
                } else {
                    if selectedNavigationItem == .settings {
                        SettingsView(viewModel: .init(keyManager: viewModel.keyManager, authManager: viewModel.authManager, fileAccess: viewModel.fileAccess))
                    } else {
                        AlbumGrid(viewModel: .init(purchaseManager: viewModel.purchasedPermissions, fileManager: viewModel.fileAccess, albumManger: viewModel.albumManager))
                    }
                    BottomNavigationBar(selectedItem: $selectedNavigationItem)
                }
            }
            .onAppear {
                if UserDefaultUtils.bool(forKey: .showCurrentAlbumOnLaunch) {
                    guard let album = viewModel.albumManager.currentAlbum else {
                        selectedNavigationItem = .albums
                        return
                    }
                    withAnimation {
                        viewModel.selectedPath.append(album)
                        UserDefaultUtils.set(false, forKey: .showCurrentAlbumOnLaunch)
                    }
                }
            }
            .onChange(of: viewModel.selectedNavigationItem, { oldValue, newValue in
                selectedNavigationItem = newValue
            })
            .toolbar(.hidden)
            .ignoresSafeArea(edges: .bottom)
            .gradientBackground()
            .screenBlocked()
            .navigationDestination(for: AppNavigationPaths.self) { destination in
                switch destination {
                case .createAlbum:
                    AlbumDetailView<D>(viewModel: .init(albumManager: viewModel.albumManager, album: nil, shouldCreateAlbum: true)).onAppear {
                        EventTracking.trackCreateAlbumButtonPressed()
                    }
                case .notificationList:
                    NotificationList()
                }
            }
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView<D>(viewModel: .init(albumManager: viewModel.albumManager, album: album)).onAppear {
                    EventTracking.trackAlbumOpened()
                }
            }
        }

    }
}

//#Preview {
//    MainHomeView(viewModel: .init(fileAccess: DemoFileEnumerator(), keyManager: DemoKeyManager(), storageSettingsManager: DemoStorageSettingsManager(), purchasedPermissions: DemoPurchasedPermissionManaging(), settingsManager: SettingsManager(), authManager: DemoAuthManager()))
//
//}
