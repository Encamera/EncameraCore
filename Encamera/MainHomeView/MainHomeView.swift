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
    @Published var hasOpenedURL: Bool = false
    @Published var promptToSaveMedia: Bool = false
    var fileAccess: FileAccess = DiskFileAccess()
    var appGroupFileAccess = AppGroupFileReader()
    var cameraService: CameraConfigurationService
    var cameraServiceModel = CameraConfigurationServiceModel()

    @Published var cameraMode: CameraMode = .photo
    @Published var rotationFromOrientation: CGFloat = 0.0
    @Published var showScreenBlocker: Bool = true
    @Published var showOnboarding = false
    @Published var isAuthenticated = false
    @Published var hasMediaToImport = false
    @Published var showImportedMediaScreen = false
    @Published var shouldShowTweetScreen: Bool = false
    @Published var showCamera: Bool = false
    var openedUrl: URL?
    var keyManager: KeyManager
    var onboardingManager: OnboardingManager
    var storageSettingsManager: DataStorageSetting = DataStorageUserDefaultsSetting()
    var purchasedPermissions: PurchasedPermissionManaging = AppPurchasedPermissionUtils()
    var settingsManager: SettingsManager
    private(set) var authManager: AuthManager
    private var cancellables = Set<AnyCancellable>()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        self.settingsManager = SettingsManager()
        self.cameraService = CameraConfigurationService(model: cameraServiceModel)
        self.authManager = DeviceAuthManager(settingsManager: settingsManager)
        let manager = MultipleKeyKeychainManager(isAuthenticated: self.authManager.isAuthenticatedPublisher, keyDirectoryStorage: storageSettingsManager)

        self.keyManager = manager

        self.onboardingManager = OnboardingManager(keyManager: keyManager, authManager: authManager, settingsManager: settingsManager)
        self.onboardingManager
            .observables
            .$shouldShowOnboarding
            .dropFirst()
            .sink { value in
            self.showOnboarding = value
        }.store(in: &cancellables)
        self.authManager
            .isAuthenticatedPublisher
            .receive(on: DispatchQueue.main)
            .sink { value in
            self.isAuthenticated = value
                self.showCamera = value
        }.store(in: &cancellables)

        do {
            try onboardingManager.loadOnboardingState()
        } catch let onboardingError as OnboardingManagerError {
            debugPrint("Onboarding error \(onboardingError)")
        } catch {
            fatalError("Onboarding error \(error)")
        }
        self.keyManager.keyPublisher.sink { newKey in
            self.setupWith(key: newKey)
        }.store(in: &cancellables)

        setupWith(key: keyManager.currentKey)
        NotificationUtils.didEnterBackgroundPublisher
            .receive(on: RunLoop.main)
            .sink { _ in

                self.showScreenBlocker = true
                TempFileAccess.cleanupTemporaryFiles()

            }.store(in: &cancellables)

        NotificationUtils.willResignActivePublisher
            .receive(on: RunLoop.main)
            .sink { _ in
                self.showScreenBlocker = true
            }
            .store(in: &cancellables)

        NotificationUtils.didBecomeActivePublisher
            .receive(on: RunLoop.main)
            .sink { _ in
                self.showScreenBlocker = false
            }.store(in: &cancellables)

        NotificationUtils.orientationDidChangePublisher
            .receive(on: RunLoop.main)
            .sink { value in

                var rotation = 0.0
                switch UIDevice.current.orientation {

                case .unknown, .portrait, .portraitUpsideDown:
                    rotation = 0.0

                case .landscapeLeft:
                    rotation = 90.0
                case .landscapeRight:
                    rotation = -90.0
                case .faceUp, .faceDown:
                    rotation = 0.0

                @unknown default:
                    rotation = 0.0
                }
                if self.rotationFromOrientation != rotation {
                    self.rotationFromOrientation = rotation
                }
            }.store(in: &cancellables)
        TempFileAccess.cleanupTemporaryFiles()
    }



    func moveOpenedFile(media: EncryptedMedia) {
        Task {
            do {
                try await fileAccess.move(media: media)
            } catch {
                print("Could not copy: ", error)
            }
            await MainActor.run {
                hasOpenedURL = false
            }
        }

    }

    private func setupWith(key: PrivateKey?) {
        Task {
            await self.fileAccess.configure(with: key, storageSettingsManager: storageSettingsManager)
            guard key != nil else { return }
            await showImportScreenIfNeeded()
            UserDefaultUtils.increaseInteger(forKey: .launchCount)
            await MainActor.run {
                self.setShouldShowTweetScreen()
            }
        }


    }

    func checkForImportedImages() async {

        let images: [CleartextMedia<URL>] = await appGroupFileAccess.enumerateMedia()
        let hasMedia = images.count > 0
        await MainActor.run {
            hasMediaToImport = hasMedia
        }


    }
    func showImportScreenIfNeeded() async {
        await checkForImportedImages()

        await MainActor.run {
            showImportedMediaScreen = hasMediaToImport
        }

    }

    @MainActor
    func setShouldShowTweetScreen() {
        let launchCount = UserDefaultUtils.integer(forKey: .launchCount)
        var shouldShow = false
        if purchasedPermissions.hasEntitlement() == true {
            shouldShow = false
        } else if launchCount % AppConstants.requestForTweetFrequency == 0  {
            shouldShow = true
        }
        debugPrint("should show tweet screen", shouldShow, launchCount)
    }
}


struct MainHomeView: View {

    @StateObject var viewModel: MainHomeViewViewModel

    @State private var selectedNavigationItem: BottomNavigationBar.ButtonItem = .albums

    var body: some View {
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
        .ignoresSafeArea(edges: .bottom)
        .gradientBackground()
    }
}

#Preview {
    MainHomeView(viewModel: .init())

}
