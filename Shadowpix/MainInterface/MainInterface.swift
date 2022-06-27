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
    @State var showGalleryView: Bool = false

    init(viewModel: MainInterfaceViewModel) {
        self.model = viewModel
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            if model.showCameraInterface,
                let cameraService = model.cameraService {
                let _ = Self._printChanges()

                let cameraModel = CameraModel(keyManager: appState.keyManager, cameraService: cameraService)
                CameraView(viewModel: cameraModel, galleryIconTapped: $showGalleryView, showingKeySelection: $model.showingKeySelection)
                    
                    .environmentObject(appState)
                    .sheet(isPresented: $model.showingKeySelection) {
                        KeySelectionList(viewModel: .init(keyManager: appState.keyManager))
                    }.sheet(isPresented: $showGalleryView) {
                        MediaGalleryView<DiskFileAccess<iCloudFilesDirectoryModel>>(viewModel: MediaGalleryViewModel(keyManager: appState.keyManager))
                    }
            } else {
                Color.black
            }
        }
    }
}

struct MainInterface_Previews: PreviewProvider {
    static var previews: some View {
        MainInterface(viewModel: MainInterfaceViewModel(keyManager: KeychainKeyManager(isAuthorized: Just(true).eraseToAnyPublisher()))).environmentObject(ShadowPixState())
    }
}
