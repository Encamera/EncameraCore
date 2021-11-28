//
//  ShadowpixApp.swift
//  Shadowpix
//
//  Created by Rolando Rodriguez on 10/15/20.
//

import SwiftUI
import LocalAuthentication

@main
struct ShadowpixApp: App {
    @State var hasOpenedUrl: Bool = false
    class ViewModel: ObservableObject {
        var openedUrl: URL?
    }
    
    @ObservedObject var state: ShadowPixState = .shared
    @StateObject var viewModel: ViewModel = ViewModel()
    @State var showGenerateKeySheet: Bool = false
    var showScannedKeySheet: Binding<Bool> = {
        return Binding {
            return ShadowPixState.shared.showScannedKeySheet
        } set: { value in
            ShadowPixState.shared.showScannedKeySheet = value
        }
    }()

    var body: some Scene {
        WindowGroup {
            CameraView().sheet(isPresented: $hasOpenedUrl) {
                self.hasOpenedUrl = false
            } content: {
                if let url = viewModel.openedUrl {
                    if url.lastPathComponent.contains(".live") {
                        MovieViewing(viewModel: MovieViewing.ViewModel(movieUrl: url, filesManager: ShadowPixState.shared.tempFilesManager))
                    } else {
                        ImageViewing(viewModel: ImageViewing.ViewModel(imageUrl: url))
                            .environmentObject(ShadowPixState.shared)
                    }
                    
                }
            }.onOpenURL { url in
                print(url)
                self.hasOpenedUrl = false
                self.viewModel.openedUrl = url
                self.hasOpenedUrl = true
            }.onAppear {
                let context = LAContext()
                var error: NSError?
                guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                    state.isAuthorized = false
                    return
                }
                
                context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Scan face ID to keep your keys secure.") { success, error in
                    DispatchQueue.main.async {
                        state.isAuthorized = success
                        guard success else {
                            return
                        }
                        if let savedKey = WorkWithKeychain.getKeyObject() {
                            ShadowPixState.shared.selectedKey = savedKey
                        } else {
                            showGenerateKeySheet = true
                        }
                    }
                }
                
            }
            .sheet(isPresented: $state.showScannedKeySheet, onDismiss: {
            }, content: {
                if let scannedKey = ShadowPixState.shared.scannedKey, let keyString = scannedKey.base64String {
                    KeyEntry(keyString: keyString, isShowing: $state.showScannedKeySheet)
                }
            })
            .sheet(isPresented: $showGenerateKeySheet) {

            } content: {
                KeyGeneration(isShown: $showGenerateKeySheet)
            }.environmentObject(ShadowPixState.shared)

        }
    }
}
