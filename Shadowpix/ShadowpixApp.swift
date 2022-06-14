//
//  ShadowpixApp.swift
//  Shadowpix
//
//  Created by Rolando Rodriguez on 10/15/20.
//

import SwiftUI

@main
struct ShadowpixApp: App {
    class ViewModel: ObservableObject {
        @Published var hasOpenedURL: Bool = false
        var openedUrl: URL?
        var state: ShadowPixState = ShadowPixState()
    }
    
    @ObservedObject var viewModel: ViewModel = ViewModel()
//    lazy var showScannedKeySheet: Binding<Bool> = {
//        return Binding {
//            return viewModel.state.showScannedKeySheet
//        } set: { value in
//            viewModel.state.showScannedKeySheet = value
//        }
//    }()
    
    var body: some Scene {
        WindowGroup {
            MainInterface(viewModel: MainInterfaceViewModel(keyManager: viewModel.state.keyManager)).sheet(isPresented: $viewModel.hasOpenedURL) {
                self.viewModel.hasOpenedURL = false
            } content: {
                if let url = viewModel.openedUrl, let media = EncryptedMedia(source: url), viewModel.state.authManager.isAuthorized {
                    switch media.mediaType {
                    case .photo:
                        ImageViewing<EncryptedMedia, DiskFileAccess<iCloudFilesDirectoryModel>>(viewModel: ImageViewingViewModel(image: media, keyManager: viewModel.state.keyManager))
                    case .video:
                        MovieViewing<EncryptedMedia, DiskFileAccess<iCloudFilesDirectoryModel>>(viewModel: MovieViewingViewModel(image: media, keyManager: viewModel.state.keyManager))
                    case .thumbnail, .unknown:
                        EmptyView()
                    }
                    
                }
            }.onOpenURL { url in
                self.viewModel.hasOpenedURL = false
                self.viewModel.openedUrl = url
                self.viewModel.hasOpenedURL = true
            }
//            .sheet(isPresented: $state.showScannedKeySheet, onDismiss: {
//            }, content: {
//                if let scannedKey = ShadowPixState.shared.scannedKey, let keyString = scannedKey.base64String {
//                    KeyEntry(keyString: keyString, isShowing: $state.showScannedKeySheet)
//                }
//            })
            .environmentObject(viewModel.state)

        }
    }
}
