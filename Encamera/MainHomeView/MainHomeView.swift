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

class MainHomeViewViewModel: ObservableObject {

    @Published var cameraMode: CameraMode = .photo
    @Published var rotationFromOrientation: CGFloat = 0.0
    @Published var showScreenBlocker: Bool = true
    @Published var showOnboarding = false
    @Published var isAuthenticated = false
    @Published var hasMediaToImport = false
    @Published var showImportedMediaScreen = false
    @Published var shouldShowTweetScreen: Bool = false

    var fileAccess: FileAccess
    var cameraService: CameraConfigurationService
    var cameraServiceModel = CameraConfigurationServiceModel()
    var keyManager: KeyManager
    var privateKey: PrivateKey
    var albumManager: AlbumManaging
    var purchasedPermissions: PurchasedPermissionManaging
    var settingsManager: SettingsManager
    private(set) var authManager: AuthManager
    private var cancellables = Set<AnyCancellable>()

    init(fileAccess: FileAccess,
         keyManager: KeyManager,
         key: PrivateKey,
         albumManager: AlbumManaging,
         purchasedPermissions: PurchasedPermissionManaging,
         settingsManager: SettingsManager,
         authManager: AuthManager) {
        self.fileAccess = fileAccess
        self.privateKey = key
        self.cameraService = CameraConfigurationService(model: cameraServiceModel)
        self.keyManager = keyManager
        self.albumManager = albumManager
        self.purchasedPermissions = purchasedPermissions
        self.settingsManager = settingsManager
        self.authManager = authManager
        self.settingsManager = SettingsManager()
        self.cameraService = CameraConfigurationService(model: cameraServiceModel)
        self.authManager = authManager
        let manager = MultipleKeyKeychainManager(isAuthenticated: self.authManager.isAuthenticatedPublisher)

        self.keyManager = manager

    }

}


struct MainHomeView: View {

    @StateObject var viewModel: MainHomeViewViewModel
    @Binding var showCamera: Bool
    @State private var selectedNavigationItem: BottomNavigationBar.ButtonItem = .albums {
        didSet {
            showCamera = false
        }
    }

    init(viewModel: MainHomeViewViewModel, showCamera: Binding<Bool>) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _showCamera = showCamera
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if selectedNavigationItem == .camera || showCamera {
                    CameraView(cameraModel: .init(
                        privateKey: viewModel.privateKey,
                        albumManager: viewModel.albumManager,
                        authManager: viewModel.authManager,
                        cameraService: viewModel.cameraService,
                        fileAccess: viewModel.fileAccess,
                        purchaseManager: viewModel.purchasedPermissions
                    ), hasMediaToImport: $viewModel.hasMediaToImport) {
                        selectedNavigationItem = .albums
                    }
                } else {
                    if selectedNavigationItem == .settings {
                        SettingsView(viewModel: .init(keyManager: viewModel.keyManager, authManager: viewModel.authManager, fileAccess: viewModel.fileAccess))
                    } else {
                        AlbumGrid(viewModel: .init(key: viewModel.privateKey, purchaseManager: viewModel.purchasedPermissions, fileManager: viewModel.fileAccess, albumManger: viewModel.albumManager))
                    }
                    BottomNavigationBar(selectedItem: $selectedNavigationItem)
                }
            }
            .toolbar(.hidden)
            .ignoresSafeArea(edges: .bottom)
            .gradientBackground()
        }
        .screenBlocked()
    }
}

//#Preview {
//    MainHomeView(viewModel: .init(fileAccess: DemoFileEnumerator(), keyManager: DemoKeyManager(), storageSettingsManager: DemoStorageSettingsManager(), purchasedPermissions: DemoPurchasedPermissionManaging(), settingsManager: SettingsManager(), authManager: DemoAuthManager()))
//
//}
