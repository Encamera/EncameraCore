//
//  MediaGalleryView.swift
//  Encamera
//
//  Created by Alexander Freas on 10.05.22.
//

import SwiftUI
import Combine

class MediaGalleryViewModel: ObservableObject {
    @Published var fileAccess: FileAccess!
    @Published var keyManager: KeyManager
    
    init(keyManager: KeyManager, fileAccess: FileAccess, storageSettingsManager: DataStorageSetting) {
        
        self.keyManager = keyManager
        self.fileAccess = fileAccess
    }
}

struct MediaGalleryView<F: FileAccess>: View {
    
    @StateObject var viewModel: MediaGalleryViewModel
    
    var body: some View {

        if let fileAccess = viewModel.fileAccess {
            GalleryView(viewModel: .init(
                fileAccess: fileAccess,
                keyManager: viewModel.keyManager
            ))
            .screenBlocked()
            .navigationTitle(viewModel.keyManager.currentKey?.name ?? "No Key")
        } else {
            EmptyView()
        }
    }
}
//
//struct MediaGalleryView_Previews: PreviewProvider {
//
//    
//    static var previews: some View {
//        MediaGalleryView<DemoFileEnumerator>(viewModel: .init(keyManager: DemoKeyManager(), storageSettingsManager: DataStorageUserDefaultsSetting()))
//            .environmentObject(EncameraState())
//    }
//}
