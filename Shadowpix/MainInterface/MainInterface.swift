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
            if let key = appState.keyManager.currentKey, let cameraService = model.cameraService {
                let cameraModel = CameraModel(keyManager: appState.keyManager, cameraService: cameraService)
                CameraView(viewModel: cameraModel, galleryIconTapped: $model.showGalleryView, showingKeySelection: $model.showingKeySelection)
                    .environmentObject(appState)
                    .sheet(isPresented: $model.showingKeySelection) {
                        KeyPickerView(isShown: $model.showingKeySelection)
                            .environmentObject(appState)
                    }.sheet(isPresented: $model.showGalleryView) {
                        MediaGalleryView<iCloudFilesEnumerator>(viewModel: MediaGalleryViewModel(directory: iCloudFilesDirectoryModel(subdirectory: MediaType.photo.path, keyName: key.name), key: key))
                        //                    GalleryView().environmentObject(appState)
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
