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

    init(keyManager: KeyManager) {
        
        self.keyManager = keyManager
        if let currentKey = keyManager.currentKey {
            self.fileAccess = F(key: currentKey, directoryModel: currentKey.storageDirectory)
        }
    }
}

struct MediaGalleryView<F: FileAccess>: View {

    @State var viewModel: MediaGalleryViewModel<F>
    @State var selectedMediaType: MediaType

    init(viewModel: MediaGalleryViewModel<F>) {
        self.viewModel = viewModel
        self.selectedMediaType = .photo
    }
    
    var body: some View {
        NavigationView {
            VStack {
                GalleryView(viewModel: .init(
                    fileAccess: viewModel.fileAccess,
                    keyManager: viewModel.keyManager
                ))
            }.navigationBarHidden(true)
        }
    }
}
//
//struct MediaGalleryView_Previews: PreviewProvider {
//
//    
//    static var previews: some View {
//        MediaGalleryView(viewModel: MediaGalleryViewModel<DemoFileEnumerator, DemoDirectoryModel>(directory: DemoDirectoryModel(), key: ImageKey(name: "test", keyBytes: [])))
//            .environmentObject(EncameraState())
//    }
//}
