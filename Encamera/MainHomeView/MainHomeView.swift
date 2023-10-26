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
    @Published var showCamera: Bool = false

    var fileAccess: FileAccess
    var cameraService: CameraConfigurationService
    var cameraServiceModel = CameraConfigurationServiceModel()
    var keyManager: KeyManager
    var storageSettingsManager: DataStorageSetting
    var purchasedPermissions: PurchasedPermissionManaging
    var settingsManager: SettingsManager
    private(set) var authManager: AuthManager
    private var cancellables = Set<AnyCancellable>()

    init(fileAccess: FileAccess, 
         keyManager: KeyManager,
         storageSettingsManager: DataStorageSetting,
         purchasedPermissions: PurchasedPermissionManaging,
         settingsManager: SettingsManager,
         authManager: AuthManager) {
        self.fileAccess = fileAccess
        self.cameraService = CameraConfigurationService(model: cameraServiceModel)
        self.keyManager = keyManager
        self.storageSettingsManager = storageSettingsManager
        self.purchasedPermissions = purchasedPermissions
        self.settingsManager = settingsManager
        self.authManager = authManager
        self.settingsManager = SettingsManager()
        self.cameraService = CameraConfigurationService(model: cameraServiceModel)
        self.authManager = authManager
        let manager = MultipleKeyKeychainManager(isAuthenticated: self.authManager.isAuthenticatedPublisher, keyDirectoryStorage: storageSettingsManager)

        self.keyManager = manager

    }

}


struct MainHomeView: View {

    @StateObject var viewModel: MainHomeViewViewModel

    @State private var selectedNavigationItem: BottomNavigationBar.ButtonItem = .albums

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if selectedNavigationItem == .camera {
                    CameraView(cameraModel: .init(
                        keyManager: viewModel.keyManager,
                        authManager: viewModel.authManager,
                        cameraService: viewModel.cameraService,
                        fileAccess: viewModel.fileAccess,
                        storageSettingsManager: viewModel.storageSettingsManager,
                        purchaseManager: viewModel.purchasedPermissions
                    ), hasMediaToImport: $viewModel.hasMediaToImport) {
                        selectedNavigationItem = .albums
                    }
                } else {
                    if selectedNavigationItem == .settings {
                        SettingsView(viewModel: .init(keyManager: viewModel.keyManager, authManager: viewModel.authManager, fileAccess: viewModel.fileAccess))
                    } else {
                        AlbumGrid(viewModel: .init(keyManager: viewModel.keyManager, purchaseManager: viewModel.purchasedPermissions, fileManager: viewModel.fileAccess))
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

#Preview {
    MainHomeView(viewModel: .init(fileAccess: DemoFileEnumerator(), keyManager: DemoKeyManager(), storageSettingsManager: DemoStorageSettingsManager(), purchasedPermissions: DemoPurchasedPermissionManaging(), settingsManager: SettingsManager(), authManager: DemoAuthManager()))

}
