//
//  MediaGalleryView.swift
//  Encamera
//
//  Created by Alexander Freas on 10.05.22.
//

import SwiftUI
import Combine

class MediaGalleryViewModel<F: FileAccess>: ObservableObject {
    @Published var fileAccess: F!
    @Published var keyManager: KeyManager
    
    init(keyManager: KeyManager, storageSettingsManager: DataStorageSetting) {
        
        self.keyManager = keyManager
        if let currentKey = keyManager.currentKey {
            self.fileAccess = F(key: currentKey, storageSettingsManager: storageSettingsManager)
        }
    }
}

struct MediaGalleryView<F: FileAccess>: View {
    
    @StateObject var viewModel: MediaGalleryViewModel<F>
    
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

struct MediaGalleryView_Previews: PreviewProvider {

    
    static var previews: some View {
        MediaGalleryView<DemoFileEnumerator>(viewModel: .init(keyManager: DemoKeyManager(), storageSettingsManager: DataStorageUserDefaultsSetting()))
            .environmentObject(EncameraState())
    }
}
