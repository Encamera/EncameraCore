import SwiftUI
import Combine
import MediaPlayer
import EncameraCore
import AVFoundation
import RevenueCat

typealias AlbumManagerType = AlbumManager
typealias FileAccessType = InteractableMediaDiskAccess

class AppModalStateModel: ObservableObject {
    @Published var currentModal: AppModal?
}

@main
struct EncameraApp: App {

    @MainActor
    class ViewModel<D: FileAccess>: ObservableObject {
        @MainActor
        @Published var hasOpenedURL: Bool = false
        @Published var promptToSaveMedia: Bool = false
        var fileAccess: D
        @Published var rotationFromOrientation: CGFloat = 0.0
        @Published var showScreenBlocker: Bool = true
        @Published var showOnboarding = false
        @Published var isAuthenticated = false
        @Published var hasMediaToImport = false
        @Published var showImportedMediaScreen = false
        @Published var keyManagerKey: PrivateKey?
        @Published var selectedPath: NavigationPath = .init()

        var openedUrl: URL?
        var keyManager: KeyManager
        var albumManager: AlbumManaging?
        var onboardingManager: OnboardingManager
        var purchasedPermissions: PurchasedPermissionManaging = AppPurchasedPermissionUtils()
        var settingsManager: SettingsManager
        var cameraService: CameraConfigurationService
        lazy var cameraModel: CameraModel? = { () -> CameraModel? in
            guard let albumManager = albumManager else {
                return nil
            }
            return CameraModel(
                albumManager: albumManager,
                cameraService: cameraService,
                fileAccess: fileAccess,
                purchaseManager: purchasedPermissions
            )
        }()
        var keychainMigrationUtil: KeychainMigrationUtil

        private(set) var authManager: AuthManager
        private var cancellables = Set<AnyCancellable>()


        init() {
            self.fileAccess = D.init()
            self.settingsManager = SettingsManager()
            self.authManager = DeviceAuthManager(settingsManager: settingsManager)
            let keyManager = KeychainManager(isAuthenticated: self.authManager.isAuthenticatedPublisher)

            self.keyManager = keyManager
            self.keychainMigrationUtil = KeychainMigrationUtil(keyManager: keyManager)
            self.onboardingManager = OnboardingManager(keyManager: keyManager, authManager: authManager, settingsManager: settingsManager)
            self.cameraService = CameraConfigurationService(model: CameraConfigurationServiceModel())
            self.keychainMigrationUtil.completeMigration()
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
            self.keyManager
                .keyPublisher
                .receive(on: RunLoop.main)
                .sink { key in
                    self.keyManagerKey = key
                    guard key != nil else {
                        return
                    }
                    let albumManager: AlbumManaging = AlbumManager(keyManager: keyManager)
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
                    self.purchasedPermissions.refreshEntitlements()
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



        func moveOpenedFile(media: InteractableMedia<EncryptedMedia>) {
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

        private func setupFileAccess(album: Album?) {
            guard let album, let albumManager else {
                debugPrint("No album")
                return
            }
            Task {
                await self.fileAccess.configure(
                    for: album,
                    albumManager: albumManager
                )
                guard keyManager.currentKey != nil else { return }
                await showImportScreenIfNeeded()
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
    @StateObject var appModalStateModel: AppModalStateModel = .init()

    var body: some Scene {

        WindowGroup {
            NavigationStack(path: $viewModel.selectedPath) {

                ZStack {
                    if viewModel.showOnboarding {
                        OnboardingHostingView<AlbumManagerType>(viewModel: .init(onboardingManager: viewModel.onboardingManager, keyManager: viewModel.keyManager, authManager: viewModel.authManager, finishedAction: {
                            viewModel.showOnboarding = false
                        }))
                    } else if viewModel.isAuthenticated == false {
                        AuthenticationView(viewModel: .init(authManager: self.viewModel.authManager, keyManager: self.viewModel.keyManager))
                    } else if viewModel.isAuthenticated == true,
                              viewModel.keyManagerKey != nil,
                              let albumManager = viewModel.albumManager {
                        MainHomeView<FileAccessType>(viewModel: .init(
                            fileAccess: viewModel.fileAccess,
                            keyManager: viewModel.keyManager,
                            albumManager: albumManager,
                            purchasedPermissions: viewModel.purchasedPermissions,
                            settingsManager: viewModel.settingsManager,
                            authManager: viewModel.authManager,
                            cameraService: viewModel.cameraService
                        ))
                        .environmentObject(appModalStateModel)

                    } else {
                        EmptyView()
                    }
                }
                .screenBlocked()
                .preferredColorScheme(.dark)
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
                                        self.appModalStateModel.currentModal = .cameraView(context: .init(sourceView: "Widget", closeButtonTapped: { targetAlbum in
//                                            if let targetAlbum {
//                                                viewModel.selectedPath.append(AppNavigationPaths.albumDetail(album: targetAlbum))
//                                            }
                                        }))
                                    }

                                default:
                                    break
                                }

                            }
                        }

                    }
                }
            }
            .onChange(of: self.appModalStateModel.currentModal, { oldValue, newValue in
                guard let newValue else { return }
                switch newValue {

                case .galleryScrollView(context: _):
                    break
                case .cameraView(context: let context):
                    viewModel.albumManager?.currentAlbum = context.album
                    break
                case .feedbackView:
                    break
                case .purchaseView(context: _):
                    break
                }
            })
            .fullScreenCover(isPresented: Binding {
                self.appModalStateModel.currentModal != nil
            } set: { newValue in
                if newValue == false {
                    self.appModalStateModel.currentModal = nil
                }
            }, content: {
                Group {
                    switch self.appModalStateModel.currentModal {
                    case .cameraView(context: let context):
                        if let cameraModel = viewModel.cameraModel {
                            CameraView(cameraModel: cameraModel, hasMediaToImport: .constant(false), closeButtonTapped: { album in
                                self.appModalStateModel.currentModal = nil

                                context.closeButtonTapped(album)
                            })
                        }
                    case .galleryScrollView(context: let context):
                        GalleryViewWrapper(viewModel: .init(
                            media: context.media,
                            initialMedia: context.targetMedia,
                            fileAccess: viewModel.fileAccess,
                            album: context.album,
                            albumManager: viewModel.albumManager,
                            purchasedPermissions: viewModel.purchasedPermissions,
                            purchaseButtonPressed: {
                            self.appModalStateModel.currentModal = .purchaseView(context: .init(sourceView: "GalleryScrollView", purchaseAction: { _ in
                            }))
                        }, reviewAlertActionPressed: { selection in
                            if selection == .no {
                                self.appModalStateModel.currentModal = .feedbackView
                            }

                        }))
                        .ignoresSafeArea(edges: [.top, .bottom, .leading, .trailing])
                    case .purchaseView(context: let context):
                        ProductStoreView(fromView: context.sourceView, purchaseAction: context.purchaseAction)
                    case .feedbackView:
                        FeedbackView()
                    case nil:
                        AnyView(EmptyView())
                    }
                }
                .environmentObject(appModalStateModel)
            })

            .statusBar(hidden: false)
            .environment(
                \.isScreenBlockingActive,
                 self.viewModel.showScreenBlocker
            )
        }
            
    }
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
            UserDefaultUtils.resetReviewMetric()
        }
        UserDefaultUtils.set(isUpgradeLaunch, forKey: .showPushNotificationPrompt)

        EventTracking.trackAppLaunched()
        LaunchCountUtils.recordCurrentVersionLaunch()

        Purchases.configure(withAPIKey: "appl_tHhKivzStYoIKvXOnWdSdhaYQlT")
        Purchases.shared.attribution.setAttributes(["piwik_visitor_id": EventTracking.shared.piwikTracker.visitorID])
        Purchases.shared.attribution.enableAdServicesAttributionTokenCollection()
#if DEBUG
        Purchases.logLevel = .debug
        Purchases.shared.invalidateCustomerInfoCache()
#endif
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
        } catch {
            print("Failed to set audio session category: \(error)")
        }
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
