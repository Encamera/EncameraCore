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
    @State var hasKey = false
    
    init(viewModel: MainInterfaceViewModel) {
        self.model = viewModel
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            if appState.keyManager.currentKey != nil,
                let cameraService = model.cameraService {
                
                let cameraModel = CameraModel(keyManager: appState.keyManager, cameraService: cameraService)
                CameraView(viewModel: cameraModel, galleryIconTapped: $model.showGalleryView, showingKeySelection: $model.showingKeySelection)
                    .environmentObject(appState)
                    .sheet(isPresented: $model.showingKeySelection) {
                        KeyPickerView(isShown: $model.showingKeySelection)
                            .environmentObject(appState)
                    }.sheet(isPresented: $model.showGalleryView) {
                        MediaGalleryView<DiskFileAccess<iCloudFilesDirectoryModel>>(viewModel: MediaGalleryViewModel(keyManager: appState.keyManager))
                    }
            } else {
                KeyPickerView(isShowingSheetForKeyEntry: false, isShowingSheetForNewKey: false, isShowingAlertForClearKey: false, isShown: Binding(get: {
                    self.hasKey
                }, set: { value in
                    
                }
                                                                                                                                                  ), appState: self._appState)
            }
        }
    }
}

struct MainInterface_Previews: PreviewProvider {
    static var previews: some View {
        MainInterface(viewModel: MainInterfaceViewModel(keyManager: KeychainKeyManager(isAuthorized: Just(true).eraseToAnyPublisher()))).environmentObject(ShadowPixState())
    }
}
