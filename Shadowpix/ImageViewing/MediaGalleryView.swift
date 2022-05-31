//
//  MediaGalleryView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 10.05.22.
//

import SwiftUI

class MediaGalleryViewModel: ObservableObject {
    @Published var selectedMediaType: MediaType = .photo
    @Published var directory: DirectoryModel
    @Published var fileAccess: FileAccess
    
    init(directory: DirectoryModel, key: ImageKey?) {
        self.directory = directory
        self.fileAccess = iCloudFilesEnumerator(directoryModel: directory, key: key)
    }
}

struct MediaGalleryView: View {
    
    @State var viewModel: MediaGalleryViewModel
    @State var selectedMediaType: MediaType = .photo
    @EnvironmentObject var state: ShadowPixState
    
    
    init(viewModel: MediaGalleryViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        let galleryViewModel = GalleryViewModel(fileEnumerator: viewModel.fileAccess)
        VStack {
            Picker("Media Type", selection: $selectedMediaType) {
                ForEach(MediaType.allCases, id: \.rawValue) { type in
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

//struct MediaGalleryView_Previews: PreviewProvider {
//
//    
//    static var previews: some View {
//        MediaGalleryView(viewModel: MediaGalleryViewModel())
//            .environmentObject(ShadowPixState())
//    }
//}
