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

@MainActor
class MainHomeViewViewModel<D: FileAccess>: ObservableObject {

    @Published var cameraMode: CameraMode = .photo
    @Published var rotationFromOrientation: CGFloat = 0.0
    @Published var showScreenBlocker: Bool = true
    @Published var isAuthenticated = false
    @Published var hasMediaToImport = false
    @Published var showImportedMediaScreen = false
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
        selectedPath.append(AppNavigationPaths.albumDetail(album: album))
    }
}


struct MainHomeView<D: FileAccess>: View {

    @StateObject var viewModel: MainHomeViewViewModel<D>
    @EnvironmentObject var appModalStateModel: AppModalStateModel

    @State private var selectedNavigationItem: BottomNavigationBar.ButtonItem = .albums

    init(viewModel: MainHomeViewViewModel<D>) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack(path: $viewModel.selectedPath) {
            ZStack(alignment: .bottom) {
                if selectedNavigationItem == .settings {
                    SettingsView(viewModel: .init(
                        keyManager: viewModel.keyManager,
                        authManager: viewModel.authManager,
                        fileAccess: viewModel.fileAccess,
                        albumManager: viewModel.albumManager,
                        purchasedPermissions: viewModel.purchasedPermissions
                    ))
                } else {
                    AlbumGrid(viewModel: .init(purchaseManager: viewModel.purchasedPermissions, fileManager: viewModel.fileAccess, albumManger: viewModel.albumManager))
                }
                BottomNavigationBar(selectedItem: $selectedNavigationItem, cameraCloseButtonTapped: { targetAlbum in
                    UserDefaultUtils.set(false, forKey: .showCurrentAlbumOnLaunch)
                    if let targetAlbum {
                        viewModel.navigateToAlbumDetailView(with: targetAlbum)
                    }
                    withAnimation {
                        selectedNavigationItem = .albums
                    }
                })
            }
            .environmentObject(appModalStateModel)
            .onAppear {
                if UserDefaultUtils.bool(forKey: .showCurrentAlbumOnLaunch) {
                    guard let album = viewModel.albumManager.currentAlbum else {
                        selectedNavigationItem = .albums
                        return
                    }
                    UserDefaultUtils.set(false, forKey: .showCurrentAlbumOnLaunch)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation {
                            viewModel.selectedPath.append(AppNavigationPaths.albumDetail(album: album))
                        }
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
                Group {
                    switch destination {
                    case .createAlbum:
                        AlbumDetailView<D>(viewModel: .init(albumManager: viewModel.albumManager, album: nil,
                                                            purchasedPermissions: viewModel.purchasedPermissions, shouldCreateAlbum: true)).onAppear {
                            EventTracking.trackCreateAlbumButtonPressed()
                        }
                    case .albumDetail(album: let album):
                        AlbumDetailView<D>(viewModel: .init(albumManager: viewModel.albumManager, album: album, purchasedPermissions: viewModel.purchasedPermissions)).onAppear {
                            EventTracking.trackAlbumOpened()
                        }
                    // Settings navigation destinations
                    case .authenticationMethod:
                        AuthenticationMethodView(authManager: viewModel.authManager, keyManager: viewModel.keyManager)
                    case .backupKeyPhrase:
                        KeyPhraseView(viewModel: .init(keyManager: viewModel.keyManager))
                    case .importKeyPhrase:
                        ImportKeyPhrase(viewModel: .init(keyManager: viewModel.keyManager))
                    case .openSource:
                        WebView(url: URL(string: "https://encamera.app/open-source/")!)
                    case .privacyPolicy:
                        WebView(url: URL(string: "https://encamera.app/privacy/")!)
                    case .termsOfUse:
                        WebView(url: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    case .eraseAllData:
                        PromptToErase(viewModel: .init(scope: .allData, keyManager: viewModel.keyManager, fileAccess: viewModel.fileAccess))
                    case .eraseAppData:
                        PromptToErase(viewModel: .init(scope: .appData, keyManager: viewModel.keyManager, fileAccess: viewModel.fileAccess))
                    case .roadmap:
                        WebView(url: URL(string: "https://encamera.featurebase.app/")!)
                    }
                }.environmentObject(appModalStateModel)
            }
        }
    }
}

//#Preview {
//    MainHomeView(viewModel: .init(fileAccess: DemoFileEnumerator(), keyManager: DemoKeyManager(), storageSettingsManager: DemoStorageSettingsManager(), purchasedPermissions: DemoPurchasedPermissionManaging(), settingsManager: SettingsManager(), authManager: DemoAuthManager()))
//
//}
