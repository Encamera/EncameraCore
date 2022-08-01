//
//  MainInterface.swift
//  Encamera
//
//  Created by Alexander Freas on 28.11.21.
//

import SwiftUI
import Combine

struct MainInterface: View {
    
    @ObservedObject private var model: MainInterfaceViewModel

    init(viewModel: MainInterfaceViewModel) {
        self.model = viewModel
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            if let fileAccess = $model.fileAccess, let cameraService = model.cameraService {
                
                
                CameraView(viewModel: .init(keyManager: model.keyManager, authManager: model.authManager, cameraService: cameraService, fileReader: fileAccess))
                    
            } else {
                Color.black
            }
        }
    }
}

struct MainInterface_Previews: PreviewProvider {
    static var previews: some View {
        MainInterface(viewModel: MainInterfaceViewModel(keyManager: MultipleKeyKeychainManager(isAuthorized: Just(true).eraseToAnyPublisher()), fileWriter: DemoFileEnumerator()))
    }
}
