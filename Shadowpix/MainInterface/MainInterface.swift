//
//  MainInterface.swift
//  Shadowpix
//
//  Created by Alexander Freas on 28.11.21.
//

import SwiftUI
import Combine

struct MainInterface: View {
    
    @ObservedObject private var model: MainInterfaceViewModel
    @EnvironmentObject var appState: ShadowPixState

    init(viewModel: MainInterfaceViewModel) {
        self.model = viewModel
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            if
//                model.showCameraInterface,
               let cameraService = model.cameraService,
               let fileAccess = appState.fileAccess {
                
                CameraView(viewModel: .init(keyManager: appState.keyManager, authManager: appState.authManager, cameraService: cameraService, fileReader: fileAccess))
                    .environmentObject(appState)
                    
            } else {
                Color.black
            }
        }
    }
}

struct MainInterface_Previews: PreviewProvider {
    static var previews: some View {
        MainInterface(viewModel: MainInterfaceViewModel(keyManager: MultipleKeyKeychainManager(isAuthorized: Just(true).eraseToAnyPublisher()))).environmentObject(ShadowPixState())
    }
}
