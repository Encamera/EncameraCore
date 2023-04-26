import SwiftUI
import Combine
import MediaPlayer
import EncameraCore

@main
struct EncameraApp: App {
    class ViewModel: ObservableObject {
        @Published var hasOpenedURL: Bool = false
        @Published var promptToSaveMedia: Bool = false
        var fileAccess: FileAccess = DiskFileAccess()
        @Published var cameraMode: CameraMode = .photo
        @Published var rotationFromOrientation: CGFloat = 0.0
        @Published var showScreenBlocker: Bool = true
        @Published var showOnboarding = false
        @Published var isAuthenticated = false
        var openedUrl: URL?
        var keyManager: KeyManager
        var cameraService: CameraConfigurationService
        var cameraServiceModel = CameraConfigurationServiceModel()
        var onboardingManager: OnboardingManager
        var storageSettingsManager: DataStorageSetting = DataStorageUserDefaultsSetting()
        var purchasedPermissions: PurchasedPermissionManaging = AppPurchasedPermissionUtils()
        var settingsManager: SettingsManager
        private(set) var authManager: AuthManager
        private var cancellables = Set<AnyCancellable>()
        
        init() {
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
                .sink { _ in

                    self.showScreenBlocker = true
                    self.cleanupTemporaryFiles()

                }.store(in: &cancellables)

            NotificationUtils.willResignActivePublisher
                .sink { _ in
                    self.showScreenBlocker = true
                }
                .store(in: &cancellables)

            NotificationUtils.didBecomeActivePublisher
                .sink { _ in
                    self.showScreenBlocker = false

                }.store(in: &cancellables)
            
            NotificationUtils.orientationDidChangePublisher
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
            cleanupTemporaryFiles()
        }
        
        
        
        func copyOpenedFile(media: EncryptedMedia) {
            Task {
                do {
                    try await fileAccess.copy(media: media)
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
            }
        }
        
        private func cleanupTemporaryFiles() {
            do {
                if FileManager.default.fileExists(atPath: URL.tempMediaDirectory.path) {
                    try FileManager.default.removeItem(at: URL.tempMediaDirectory)
                    debugPrint("Deleted files at \(URL.tempMediaDirectory)")
                } else {
                    debugPrint("No temporary media directory, not deleting")
                }
            } catch let error {
                debugPrint("Could not delete files: \(error)")
            }
        }
    }
    
    @StateObject var viewModel: ViewModel = .init()
    
    var body: some Scene {
        
        WindowGroup {
            CameraView(cameraModel: .init(
                keyManager: viewModel.keyManager,
                authManager: viewModel.authManager,
                cameraService: viewModel.cameraService,
                fileAccess: viewModel.fileAccess,
                storageSettingsManager: viewModel.storageSettingsManager,
                purchaseManager: viewModel.purchasedPermissions
            ))
                .preferredColorScheme(.dark)
                .sheet(isPresented: $viewModel.hasOpenedURL) {
                    if let url = viewModel.openedUrl,
                       let urlType = URLType(url: url),
                       viewModel.authManager.isAuthenticated {
                        switch urlType {
                        case .media(let encryptedMedia):
                            galleryForMedia(media: encryptedMedia)
                        case .key(let key):
                            NavigationView {
                                let dismissBinding = Binding {
                                    !viewModel.hasOpenedURL
                                } set: { value in
                                    viewModel.hasOpenedURL = !value
                                }

                                KeyEntry(viewModel: .init(enteredKey: key, keyManager: viewModel.keyManager, showCancelButton: true, dismiss: dismissBinding ))
                            }
                        case .featureToggle(feature: let feature):
                            Text("Feature \"\(feature.rawValue)\" activated").onAppear {
                                FeatureToggle.enable(feature: feature)
                            }
                        }
                        
                    } else {
                        Text(L10n.noPrivateKeyOrMediaFound)
                            .fontType(.medium)
                    }
                }
                .overlay {
                    if viewModel.showOnboarding {
                        MainOnboardingView(
                            viewModel: .init(onboardingManager: viewModel.onboardingManager,
                                             keyManager: viewModel.keyManager, authManager: viewModel.authManager))
                    } else if viewModel.isAuthenticated == false {
                        AuthenticationView(viewModel: .init(authManager: self.viewModel.authManager, keyManager: self.viewModel.keyManager))
                    }
                }
                .environment(\.rotationFromOrientation, viewModel.rotationFromOrientation)
                .onOpenURL { url in
                    Task {
                        self.viewModel.hasOpenedURL = false
                        guard case .authenticated(_) = await self.viewModel.authManager.waitForAuthResponse() else {
                            return
                        }
                        self.viewModel.openedUrl = url
                        self.viewModel.hasOpenedURL = true
                    }
                }
                .statusBar(hidden: true)
                .environment(
                    \.isScreenBlockingActive,
                     self.viewModel.showScreenBlocker
                )
                .onAppear {
                    UserDefaultUtils.migrateUserDefaultsToAppGroups()
                }
        }
    }
    
    @ViewBuilder private func galleryForMedia(media: EncryptedMedia) -> some View {
        let fileAccess = viewModel.fileAccess
        switch media.mediaType {
        case .photo:
            NavigationView {
                GalleryHorizontalScrollView(
                    viewModel: GalleryHorizontalScrollViewModel.init(
                        media: [media],
                        selectedMedia: media,
                        fileAccess: fileAccess,
                        showActionBar: false,
                        purchasedPermissions: viewModel.purchasedPermissions
                    )
                ).toolbar {
                    Button(L10n.close) {
                        self.viewModel.promptToSaveMedia = true
                    }
                }
                .alert(L10n.saveThisMedia, isPresented: $viewModel.promptToSaveMedia) {
                    Text(L10n.thisWillSaveTheMediaToYourLibrary)
                    Button(L10n.cancel, role: .cancel) {
                        self.viewModel.hasOpenedURL = false
                    }
                    Button(L10n.save) {
                        viewModel.copyOpenedFile(media: media)
                    }
                }
                
            }
        case .video:
            MovieViewing<EncryptedMedia>(viewModel: MovieViewingViewModel(media: media, fileAccess: fileAccess))
        default:
            EmptyView()
        }
    }
}
