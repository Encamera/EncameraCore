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
    
    var body: some Scene {
        WindowGroup {
            MainInterface(viewModel: MainInterfaceViewModel(keyManager: viewModel.state.keyManager))
                .sheet(isPresented: $viewModel.hasOpenedURL) {
                    self.viewModel.hasOpenedURL = false
                } content: {
                    if let url = viewModel.openedUrl,
                        let media = EncryptedMedia(source: url),
                        viewModel.state.authManager.isAuthorized,
                       let fileAccess = viewModel.state.fileAccess {
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
            .environmentObject(viewModel.state)

        }
    }
}
