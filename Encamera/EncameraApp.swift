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
        var newMediaFileAccess: FileAccess = DiskFileAccess()
        var appGroupFileAccess: AppGroupFileReader?
        @Published var rotationFromOrientation: CGFloat = 0.0
        @Published var showScreenBlocker: Bool = true
        @Published var showOnboarding = false
        @Published var isAuthenticated = false
        @Published var hasMediaToImport = false
        @Published var showImportedMediaScreen = false
        @Published var shouldShowTweetScreen: Bool = false
        @Published var keyManagerKey: PrivateKey?
        var openedUrl: URL?
        var keyManager: KeyManager
        var albumManager: AlbumManaging?
        var onboardingManager: OnboardingManager
        var purchasedPermissions: PurchasedPermissionManaging = AppPurchasedPermissionUtils()
        var settingsManager: SettingsManager
        private(set) var authManager: AuthManager
        private var cancellables = Set<AnyCancellable>()
        
        init() {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)

            self.settingsManager = SettingsManager()
            self.authManager = DeviceAuthManager(settingsManager: settingsManager)
            let keyManager = MultipleKeyKeychainManager(isAuthenticated: self.authManager.isAuthenticatedPublisher)

            self.keyManager = keyManager
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
            self.keyManager.keyPublisher.sink { key in
                self.keyManagerKey = key
                guard let key else {
                    return
                }
                let albumManager: AlbumManaging = AlbumManager(keyManager: keyManager)
                self.appGroupFileAccess = AppGroupFileReader(albumManager: albumManager)
                self.albumManager = albumManager
                self.albumManager?.selectedAlbumPublisher.sink { newAlbum in
                    self.setupFileAccess(with: self.keyManager.currentKey, album: newAlbum)
                }.store(in: &self.cancellables)
                self.setupFileAccess(with: key, album: albumManager.currentAlbum)

            }.store(in: &cancellables)



            setupFileAccess(with: keyManager.currentKey, album: albumManager?.currentAlbum)
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
                    try await newMediaFileAccess.move(media: media)
                } catch {
                    print("Could not copy: ", error)
                }
                await MainActor.run {
                    hasOpenedURL = false
                }
            }

        }
        
        private func setupFileAccess(with key: PrivateKey?, album: Album?) {
            guard let album, let albumManager else {
                debugPrint("No album")
                return
            }
            Task {
                await self.newMediaFileAccess.configure(
                    for: album,
                    with: key,
                    albumManager: albumManager
                )
                guard keyManager.currentKey != nil else { return }
                await showImportScreenIfNeeded()
                UserDefaultUtils.increaseInteger(forKey: .launchCount)
                await MainActor.run {
                    self.setShouldShowTweetScreen()
                }
            }
        }
        
        func checkForImportedImages() async {
            
            guard let images: [CleartextMedia<URL>] = await appGroupFileAccess?.enumerateMedia() else {
                return
            }
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
    @State var showCamera = false
    var body: some Scene {
        
        WindowGroup {
            ZStack {
                
                if viewModel.showOnboarding {
                    MainOnboardingView(
                        viewModel: OnboardingViewModel<AlbumManager>(onboardingManager: viewModel.onboardingManager,
                                         keyManager: viewModel.keyManager,
                                         authManager: viewModel.authManager))
                } else if viewModel.isAuthenticated == false && viewModel.keyManagerKey == nil {
                    AuthenticationView(viewModel: .init(authManager: self.viewModel.authManager, keyManager: self.viewModel.keyManager))
                } else if viewModel.isAuthenticated == true, let key = viewModel.keyManagerKey, let albumManager = viewModel.albumManager {
                    MainHomeView(viewModel: .init(
                        fileAccess: viewModel.newMediaFileAccess,
                        keyManager: viewModel.keyManager,
                        key: key,
                        albumManager: albumManager,
                        purchasedPermissions: viewModel.purchasedPermissions,
                        settingsManager: viewModel.settingsManager,
                        authManager: viewModel.authManager), showCamera: $showCamera)

                } else {
                    EmptyView()
                }
            }
                .preferredColorScheme(.dark)
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
                .environment(\.rotationFromOrientation, viewModel.rotationFromOrientation)
                .onOpenURL { url in
                    Task {
                        await MainActor.run {
                            self.viewModel.hasOpenedURL = false
                        }

                        guard case .authenticated(_) = await self.viewModel.authManager.waitForAuthResponse() else {
                            return
                        }
                        await MainActor.run {
                            self.viewModel.openedUrl = url
                            self.viewModel.hasOpenedURL = true
                            if let url = viewModel.openedUrl,
                               let urlType = URLType(url: url),
                               viewModel.authManager.isAuthenticated,
                               urlType == .camera {
                                self.showCamera = true
                            }
                        }

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
        if let key = viewModel.keyManager.currentKey, let albumManager = viewModel.albumManager {
            MediaImportView(viewModel: .init(
                privateKey: key,
                albumManager: albumManager,
                fileAccess: viewModel.newMediaFileAccess))
        } else {
            Text("Something went wrong")
        }
    }

    @ViewBuilder private func galleryForMedia(media: EncryptedMedia) -> some View {
        let fileAccess = viewModel.newMediaFileAccess
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
