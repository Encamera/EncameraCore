//
//  MediaGalleryView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 10.05.22.
//

import SwiftUI

class MediaGalleryViewModel<F: FileAccess>: ObservableObject {
    @Published var selectedMediaType: MediaType = .photo
    @Published var directory: DirectoryModel
    @Published var fileAccess: F
    @Published var key: ImageKey?
    
    init(directory: DirectoryModel, key: ImageKey?) {
        self.directory = directory
        self.key = key
        self.fileAccess = F(key: key)
    }
}

struct MediaGalleryView<F: FileAccess>: View {
    
    @State var viewModel: MediaGalleryViewModel<F>
    @State var selectedMediaType: MediaType = .photo
    @EnvironmentObject var state: ShadowPixState
    
    
    init(viewModel: MediaGalleryViewModel<F>) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        let galleryViewModel = GalleryViewModel(sourceDirectory: viewModel.directory, fileAccess: viewModel.fileAccess, keyManager: state.keyManager)
        VStack {
            Picker("Media Type", selection: $selectedMediaType) {
                ForEach(MediaType.displayCases, id: \.rawValue) { type in
                    Text(type.title).tag(type.rawValue)
                }
            }.pickerStyle(.segmented)
                .onChange(of: selectedMediaType) { newValue in
//                    let directoryModel = iCloudFilesDirectoryModel(subdirectory: newValue.path, keyName: "")
//
//                    self.fileEnumerator = F(directoryModel: directoryModel, key: state.selectedKey)
                }
            GalleryView(viewModel: galleryViewModel)
        }
    }
}

struct MediaGalleryView_Previews: PreviewProvider {

    
    static var previews: some View {
        MediaGalleryView(viewModel: MediaGalleryViewModel<DemoFileEnumerator>(directory: DemoDirectoryModel(), key: nil))
            .environmentObject(ShadowPixState())
    }
}
