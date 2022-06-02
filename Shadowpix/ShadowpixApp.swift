//
//  ShadowpixApp.swift
//  Shadowpix
//
//  Created by Rolando Rodriguez on 10/15/20.
//

import SwiftUI

@main
struct ShadowpixApp: App {
    @State var hasOpenedUrl: Bool = false
    class ViewModel: ObservableObject {
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
            MainInterface().sheet(isPresented: $hasOpenedUrl) {
                self.hasOpenedUrl = false
            } content: {
                if let url = viewModel.openedUrl {
//                    if url.lastPathComponent.contains(".live") {
//                        MovieViewing(viewModel: MovieViewing.ViewModel(movieUrl: url, filesManager: state.tempFilesManager))
//                    } else {
                    let media = EncryptedMedia(source: url)
                    
                    ImageViewing<EncryptedMedia, iCloudFilesEnumerator>(viewModel: ImageViewing.ViewModel(image: media, keyManager: viewModel.state.keyManager))
//                    }
                    
                }
            }.onOpenURL { url in
                self.hasOpenedUrl = false
                self.viewModel.openedUrl = url
                self.hasOpenedUrl = true
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
