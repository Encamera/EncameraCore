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
            if let key = appState.keyManager.currentKey {
                let fileWriter = iCloudFilesEnumerator(key: key)
            CameraView(viewModel: CameraModel(keyManager: appState.keyManager, fileWriter: fileWriter), galleryIconTapped: $model.showGalleryView, showingKeySelection: $model.showingKeySelection)
                .environmentObject(appState)
                .sheet(isPresented: $model.showingKeySelection) {
                    KeyPickerView(isShown: $model.showingKeySelection)
                        .environmentObject(appState)
                }.sheet(isPresented: $model.showGalleryView) {
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
