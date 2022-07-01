//
//  ShadowpixApp.swift
//  Shadowpix
//
//  Created by Rolando Rodriguez on 10/15/20.
//

import SwiftUI
import Combine

@main
struct ShadowpixApp: App {
    class ViewModel: ObservableObject {
        @Published var hasOpenedURL: Bool = false
        var openedUrl: URL?
        @Published var fileAccess: DiskFileAccess<iCloudFilesDirectoryModel>?
        var keyManager: KeyManager
        private(set) var authManager: AuthManager
        private var cancellables = Set<AnyCancellable>()
        @Published var cameraMode: CameraMode = .photo
        @Published var cameraService: CameraService?

        var tempFilesManager: TempFilesManager = TempFilesManager.shared

        init() {
            
            self.authManager = AuthManager()
            self.keyManager = MultipleKeyKeychainManager(isAuthorized: self.authManager.$isAuthorized.eraseToAnyPublisher())
            self.keyManager.keyPublisher.sink { newKey in
                guard let key = newKey else {
                    return
                }
                let fileAccess = DiskFileAccess<iCloudFilesDirectoryModel>(key: key)
                self.cameraService = CameraService(model: CameraServiceModel(keyManager: self.keyManager, fileWriter: fileAccess))
                self.fileAccess = fileAccess
            }.store(in: &cancellables)
            
            NotificationCenter.default
                .publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { _ in
                    self.authManager.deauthorize()
                }.store(in: &cancellables)
            NotificationCenter.default
                .publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { _ in
                    self.authManager.authorize()
                }.store(in: &cancellables)
        }
    }
    
    @ObservedObject var viewModel: ViewModel = ViewModel()
    
    var body: some Scene {
        WindowGroup {
            if let fileAccess = viewModel.fileAccess, let cameraService = viewModel.cameraService {
            CameraView(viewModel: .init(keyManager: viewModel.keyManager, authManager: viewModel.authManager, cameraService: cameraService, fileReader: fileAccess))
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
                        case .thumbnail, .unknown:
                            EmptyView()
                    }
                    
                }
            }.onOpenURL { url in
                self.viewModel.hasOpenedURL = false
                self.viewModel.openedUrl = url
                self.viewModel.hasOpenedURL = true
            }
            } else {
                Color.black
            }

        }
    }
}
