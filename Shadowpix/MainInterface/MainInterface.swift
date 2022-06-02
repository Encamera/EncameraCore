//
//  MainInterface.swift
//  Shadowpix
//
//  Created by Alexander Freas on 28.11.21.
//

import SwiftUI

struct MainInterface: View {
    
    @StateObject private var model = MainInterfaceViewModel()
    @EnvironmentObject var appState: ShadowPixState
    var body: some View {
        ZStack(alignment: .top) {
            CameraView(keyManager: appState.keyManager, galleryIconTapped: $model.showGalleryView, showingKeySelection: $model.showingKeySelection)
                .environmentObject(appState)
                .sheet(isPresented: $model.showingKeySelection) {
                    KeyPickerView(isShown: $model.showingKeySelection)
                        .environmentObject(appState)
                }.sheet(isPresented: $model.showGalleryView) {
//                    GalleryView().environmentObject(appState)
                }
        }
    }
}

struct MainInterface_Previews: PreviewProvider {
    static var previews: some View {
        MainInterface().environmentObject(ShadowPixState())
    }
}
