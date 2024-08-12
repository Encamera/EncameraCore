import SwiftUI
import Combine
import MediaPlayer
import EncameraCore
import AVFoundation

typealias AlbumManagerType = AlbumManager
typealias FileAccessType = InteractableMediaDiskAccess

@main
struct EncameraApp: App {
    class ViewModel<D: FileAccess>: ObservableObject {
        @MainActor
        @Published var hasOpenedURL: Bool = false
        @Published var promptToSaveMedia: Bool = false
        var newMediaFileAccess: D
//        var appGroupFileAccess: AppGroupFileReader?
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
        var cameraService: CameraConfigurationService
        private(set) var authManager: AuthManager
        private var cancellables = Set<AnyCancellable>()

        init() {
            self.newMediaFileAccess = D.init()
            self.settingsManager = SettingsManager()
            self.authManager = DeviceAuthManager(settingsManager: settingsManager)
            let keyManager = MultipleKeyKeychainManager(isAuthenticated: self.authManager.isAuthenticatedPublisher)

            self.keyManager = keyManager
            self.onboardingManager = OnboardingManager(keyManager: keyManager, authManager: authManager, settingsManager: settingsManager)
            self.cameraService = CameraConfigurationService(model: CameraConfigurationServiceModel())
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
                guard key != nil else {
                    return
                }
                let albumManager: AlbumManaging = AlbumManager(keyManager: keyManager)
//                self.appGroupFileAccess = AppGroupFileReader(albumManager: albumManager)
                self.albumManager = albumManager
                self.albumManager?.albumOperationPublisher
                    .receive(on: RunLoop.main)
                    .sink { operation in
                    guard case .selectedAlbumChanged(let album) = operation else {
                        return
                    }

                    self.setupFileAccess(album: album)
                }.store(in: &self.cancellables)
                self.setupFileAccess(album: albumManager.currentAlbum)

            }.store(in: &cancellables)

            

            setupFileAccess(album: albumManager?.currentAlbum)
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

            FileOperationBus
                .shared
                .operations
                .sink { operation in
                switch operation {
                case .create(_):
                    NotificationLogic.setNotificationsForMediaAdded()
                default:
                    break
                }
            }.store(in: &cancellables)
        }
        
        
        
        func moveOpenedFile(media: InteractableMedia<EncryptedMedia>) {
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
        
        private func setupFileAccess(album: Album?) {
            guard let album, let albumManager else {
                debugPrint("No album")
                return
            }
            Task {
                await self.newMediaFileAccess.configure(
                    for: album,
                    albumManager: albumManager
                )
                guard keyManager.currentKey != nil else { return }
                await showImportScreenIfNeeded()
                await MainActor.run {
                    self.setShouldShowTweetScreen()
                }
            }
        }
        
        func checkForImportedImages() async {
            
//            guard let images: [CleartextMedia] = await appGroupFileAccess?.enumerateMedia() else {
//                return
//            }
//            let hasMedia = images.count > 0
//            await MainActor.run {
//                hasMediaToImport = hasMedia
//            }


        }
        func showImportScreenIfNeeded() async {
            await checkForImportedImages()
            
            await MainActor.run {
                showImportedMediaScreen = hasMediaToImport
            }

        }
        
        @MainActor
        func setShouldShowTweetScreen() {
            let launchCount = LaunchCountUtils.fetchCurrentVersionLaunchCount()
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

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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

    @StateObject var viewModel: ViewModel<FileAccessType> = .init()
    @State var showCamera = false
    var body: some Scene {
        
        WindowGroup {
            ZStack {
                if viewModel.showOnboarding {
                    NewOnboardingHostingView<AlbumManagerType>(viewModel: .init(onboardingManager: viewModel.onboardingManager, keyManager: viewModel.keyManager, authManager: viewModel.authManager, finishedAction: {
                        viewModel.showOnboarding = false
                    }))
                } else if viewModel.isAuthenticated == false && viewModel.keyManagerKey == nil {
                    AuthenticationView(viewModel: .init(authManager: self.viewModel.authManager, keyManager: self.viewModel.keyManager))
                } else if viewModel.isAuthenticated == true,
                            viewModel.keyManagerKey != nil,
                            let albumManager = viewModel.albumManager {
                    MainHomeView<FileAccessType>(viewModel: .init(
                        fileAccess: viewModel.newMediaFileAccess,
                        keyManager: viewModel.keyManager,
                        albumManager: albumManager,
                        purchasedPermissions: viewModel.purchasedPermissions,
                        settingsManager: viewModel.settingsManager,
                        authManager: viewModel.authManager,
                        cameraService: viewModel.cameraService
                    ), showCamera: $showCamera)

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
                               viewModel.authManager.isAuthenticated {
                                switch urlType {

                                case .featureToggle(let feature):
                                    FeatureToggle.enable(feature: feature)
                                case .cameraFromWidget:
                                    UserDefaultUtils.increaseInteger(forKey: .widgetOpenCount)
                                    EventTracking.trackOpenedCameraFromWidget()
                                    withAnimation {
                                        self.showCamera = true
                                    }

                                default:
                                    break
                                }

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
//        if let key = viewModel.keyManager.currentKey, let albumManager = viewModel.albumManager {
//            MediaImportView(viewModel: .init(
//                privateKey: key,
//                albumManager: albumManager,
//                fileAccess: viewModel.newMediaFileAccess))
//        } else {
            Text("Something went wrong")
//        }
    }

//    @ViewBuilder private func galleryForMedia(media: InteractableMedia<EncryptedMedia>) -> some View {
//        let fileAccess = viewModel.newMediaFileAccess
//        switch media.mediaType {
//        case .stillPhoto, .livePhoto:
//            NavigationStack {
//                GalleryHorizontalScrollView(
//                    viewModel: GalleryHorizontalScrollViewModel.init(
//                        media: [media],
//                        selectedMedia: media,
//                        fileAccess: fileAccess,
//                        showActionBar: false,
//                        purchasedPermissions: viewModel.purchasedPermissions
//                    )
//                ).toolbar {
//                    Button(L10n.close) {
//                        self.viewModel.promptToSaveMedia = true
//                    }
//                }
//                .alert(L10n.saveThisMedia, isPresented: $viewModel.promptToSaveMedia) {
//                    Text(L10n.thisWillSaveTheMediaToYourLibrary)
//                    Button(L10n.cancel, role: .cancel) {
//                        self.viewModel.hasOpenedURL = false
//                    }
//                    Button(L10n.save) {
//                        viewModel.moveOpenedFile(media: media)
//                    }
//                }
//                
//            }
//        case .video:
//            var isPlaying = false
//            let playBinding = Binding<Bool>(get: {
//                isPlaying
//            }, set: { value in
//                isPlaying = value
//            })
//            MovieViewing(viewModel: MovieViewingViewModel(media: media, fileAccess: fileAccess), isPlayingVideo: playBinding)
//        default:
//            EmptyView()
//        }
//    }

    
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        let isUpgradeLaunch = true
        #else
        let isUpgradeLaunch = LaunchCountUtils.isUpgradeLaunch()
        #endif
        if isUpgradeLaunch {

            do {
                try DiskFileAccess.deleteThumbnailDirectory()
                debugPrint("Deleted thumbnail directory")
            } catch {
                debugPrint("Could not delete thumbnail directory")
            }
        }
        EventTracking.trackAppLaunched()
        LaunchCountUtils.recordCurrentVersionLaunch()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any]) async -> UIBackgroundFetchResult {
        // Handle your notification and update the UI or fetch data here
        print("Received remote notification: \(userInfo)")

        return .newData
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        EventTracking.trackNotificationOpened(name: identifier)
        NotificationManager.handleNotificationOpen(with: identifier)
        completionHandler()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let token = tokenParts.joined()
        print("Device Token: \(token)")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for remote notifications: \(error)")
    }
}
