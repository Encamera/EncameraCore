import SwiftUI
import Combine

@main
struct EncameraApp: App {
    class ViewModel: ObservableObject {
        @Published var hasOpenedURL: Bool = false
        @Published var fileAccess: FileAccess?
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
            self.onboardingManager.observables.$shouldShowOnboarding.dropFirst().sink { value in
                self.showOnboarding = value
            }.store(in: &cancellables)
            self.authManager.isAuthenticatedPublisher.sink { value in
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
            setupAppearances()

        }
        
        private func setupWith(key: ImageKey?) {
            guard let key = key else {
                return
            }
            let fileAccess = DiskFileAccess(key: key, storageSettingsManager: storageSettingsManager)
            self.fileAccess = fileAccess

        }
        
        private func setupAppearances() {
            let navBarAppearance = UINavigationBar.appearance()
            navBarAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
            navBarAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
            UITableView.appearance().separatorStyle = .none
            UITableViewCell.appearance().backgroundColor = .gray
            UITableView.appearance().backgroundColor = .black

        }
    }
    
    @ObservedObject var viewModel: ViewModel

    @ObservedObject var cameraModel: CameraModel
    
    init() {
        let model = ViewModel()
        self.viewModel = model
        self.cameraModel = .init(
            keyManager: model.keyManager,
            authManager: model.authManager,
            cameraService: model.cameraService,
            showScreenBlocker: model.$showScreenBlocker.eraseToAnyPublisher(),
            storageSettingsManager: model.storageSettingsManager
        )
    }
    var body: some Scene {
        
        WindowGroup {
            
            
            CameraView(viewModel: cameraModel)
                .sheet(isPresented: $viewModel.hasOpenedURL) {
                    self.viewModel.hasOpenedURL = false
                } content: {
                    if let url = viewModel.openedUrl,
                       let media = EncryptedMedia(source: url),
                       viewModel.authManager.isAuthenticated,
                       let fileAccess = viewModel.fileAccess {
                        switch media.mediaType {
                        case .photo:
                            ImageViewing<EncryptedMedia>(viewModel: ImageViewingViewModel(media: media, fileAccess: fileAccess))
                        case .video:
                            MovieViewing<EncryptedMedia>(viewModel: MovieViewingViewModel(media: media, fileAccess: fileAccess))
                        default:
                            EmptyView()
                        }
                        
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
                    self.viewModel.hasOpenedURL = false
                    self.viewModel.openedUrl = url
                    self.viewModel.hasOpenedURL = true
                }.statusBar(hidden: true)

            
        }
    }
}
