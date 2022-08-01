//
//  EncameraApp.swift
//  Encamera
//
//  Created by Rolando Rodriguez on 10/15/20.
//

import SwiftUI
import Combine

@main
struct EncameraApp: App {
    class ViewModel: ObservableObject {
        @Published var hasOpenedURL: Bool = false
        @Published var fileAccess: DiskFileAccess<iCloudFilesDirectoryModel>?
        @Published var cameraMode: CameraMode = .photo
        @Published var rotationFromOrientation: CGFloat = 0.0
        @Published var showScreenBlocker: Bool = true
        @Published var showOnboarding = false
        @Published var isAuthorized = false
        var openedUrl: URL?
        var keyManager: KeyManager
        var cameraService: CameraConfigurationService
        var cameraServiceModel = CameraConfigurationServiceModel()
        var tempFilesManager: TempFilesManager = TempFilesManager.shared
        var onboardingManager: OnboardingManager
        private(set) var authManager: AuthManager
        private var cancellables = Set<AnyCancellable>()
        
        init() {
            
            self.cameraService = CameraConfigurationService(model: cameraServiceModel)
            self.authManager = DeviceAuthManager()
            let manager = MultipleKeyKeychainManager(isAuthorized: self.authManager.isAuthorizedPublisher)
            
            self.keyManager = manager
            
            self.onboardingManager = OnboardingManager(keyManager: keyManager, authManager: authManager)
            self.onboardingManager.$shouldShowOnboarding.sink { value in
                self.showOnboarding = value
            }.store(in: &cancellables)
            self.authManager.isAuthorizedPublisher.sink { value in
                self.isAuthorized = value
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
            NotificationCenter.default
                .publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { _ in

                    self.authManager.deauthorize()
                    self.showScreenBlocker = true
                }.store(in: &cancellables)
            NotificationCenter.default
                .publisher(for: UIApplication.willResignActiveNotification)
                .sink { _ in
                    self.showScreenBlocker = true
                }
                .store(in: &cancellables)
            NotificationCenter.default
                .publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { _ in
                    self.showScreenBlocker = false
                    Task {
                        try? await self.authManager.checkAuthorizationWithCurrentPolicy()
                    }

                }.store(in: &cancellables)
            NotificationCenter.default
                .publisher(for: UIDevice.orientationDidChangeNotification)
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
                    self.rotationFromOrientation = rotation
                }.store(in: &cancellables)
        }
        
        private func setupWith(key: ImageKey?) {
            guard let key = key else {
                return
            }
            let fileAccess = DiskFileAccess<iCloudFilesDirectoryModel>(key: key)
            self.fileAccess = fileAccess

        }
    }
    
    @ObservedObject var viewModel: ViewModel = ViewModel()

    var body: some Scene {
        WindowGroup {
            
            if viewModel.isAuthorized == false || viewModel.showOnboarding == true {
                AuthenticationView(viewModel: .init(authManager: self.viewModel.authManager, keyManager: self.viewModel.keyManager))
                    .sheet(isPresented: $viewModel.showOnboarding) {
                        MainOnboardingView(
                            viewModel: .init(onboardingManager: viewModel.onboardingManager,
                                             keyManager: viewModel.keyManager, authManager: viewModel.authManager))
                    }.interactiveDismissDisabled()
            } else if let fileAccess = viewModel.fileAccess {
                CameraView(viewModel: .init(keyManager: viewModel.keyManager, authManager: viewModel.authManager, cameraService: viewModel.cameraService, fileAccess: fileAccess, showScreenBlocker: viewModel.showScreenBlocker))
                    .sheet(isPresented: $viewModel.hasOpenedURL) {
                        self.viewModel.hasOpenedURL = false
                    } content: {
                        if let url = viewModel.openedUrl,
                           let media = EncryptedMedia(source: url),
                           viewModel.authManager.isAuthorized,
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
                    .environment(\.rotationFromOrientation, viewModel.rotationFromOrientation)
                    .onOpenURL { url in
                        self.viewModel.hasOpenedURL = false
                        self.viewModel.openedUrl = url
                        self.viewModel.hasOpenedURL = true
                    }
                
            }
            
        }
    }
}
