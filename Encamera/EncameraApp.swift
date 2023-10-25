import SwiftUI
import Combine
import MediaPlayer
import EncameraCore
import AVFoundation

@main
struct EncameraApp: App {
    class ViewModel: ObservableObject {
        @Published var hasOpenedURL: Bool = false
        @Published var promptToSaveMedia: Bool = false
        var fileAccess: FileAccess = DiskFileAccess()
        var appGroupFileAccess = AppGroupFileReader()
        @Published var rotationFromOrientation: CGFloat = 0.0
        @Published var showScreenBlocker: Bool = true
        @Published var showOnboarding = false
        @Published var isAuthenticated = false
        @Published var hasMediaToImport = false
        @Published var showImportedMediaScreen = false
        @Published var shouldShowTweetScreen: Bool = false
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
//            shouldShowTweetScreen = shouldShow
        }
    }
    init() {
        _viewModel = StateObject(wrappedValue: .init())
        let appear = UINavigationBar.appearance().standardAppearance

        let atters: [NSAttributedString.Key: Any] = [
            .font: UIFont(name: "Satoshi-Bold", size: 24)!
        ]

        appear.largeTitleTextAttributes = atters
        appear.titleTextAttributes = atters
        UINavigationBar.appearance().standardAppearance = appear
        UINavigationBar.appearance().compactAppearance = appear
        UINavigationBar.appearance().scrollEdgeAppearance = appear

    }

    @StateObject var viewModel: ViewModel = .init()
    var body: some Scene {
        
        WindowGroup {
            MainHomeView(viewModel: .init(
                fileAccess: viewModel.fileAccess,
                keyManager: viewModel.keyManager,
                storageSettingsManager: viewModel.storageSettingsManager,
                purchasedPermissions: viewModel.purchasedPermissions,
                settingsManager: viewModel.settingsManager,
                authManager: viewModel.authManager))
                .preferredColorScheme(.dark)
                .sheet(isPresented: $viewModel.hasOpenedURL) {
                    openUrlSheet
                }
                .sheet(isPresented: $viewModel.showImportedMediaScreen) {
                    mediaImportSheet.onDisappear {
                        Task {
                            await viewModel.checkForImportedImages()
                        }
                    }
                }
                .sheet(isPresented: $viewModel.shouldShowTweetScreen) {
                    TweetToShareView()
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
        }
    }
    
    @ViewBuilder private var mediaImportSheet: some View {
        
        MediaImportView(viewModel: .init(keyManager: viewModel.keyManager, fileAccess: viewModel.fileAccess))
        
    }
    
    @ViewBuilder private var openUrlSheet: some View {
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
                        viewModel.moveOpenedFile(media: media)
                    }
                }
                
            }
        case .video:
            var isPlaying = false
            let playBinding = Binding<Bool>(get: {
                isPlaying
            }, set: { value in
                isPlaying = value
            })
            MovieViewing<EncryptedMedia>(viewModel: MovieViewingViewModel(media: media, fileAccess: fileAccess), isPlayingVideo: playBinding)
        default:
            EmptyView()
        }
    }
}
