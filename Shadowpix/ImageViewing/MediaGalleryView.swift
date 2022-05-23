//
//  MediaGalleryView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 10.05.22.
//

import SwiftUI

class MediaGalleryViewModel: ObservableObject {
    @Published var selectedMediaType: MediaType = .photo
}

struct MediaGalleryView: View {
    
    @State var viewModel: MediaGalleryViewModel
    @State var selectedMediaType: MediaType = .photo
    @EnvironmentObject var state: ShadowPixState
    
    var body: some View {
        let galleryViewModel = GalleryViewModel(fileEnumerator: state.fileHandler!)
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

struct MediaGalleryView_Previews: PreviewProvider {

    
    static var previews: some View {
        MediaGalleryView(viewModel: MediaGalleryViewModel())
            .environmentObject(ShadowPixState())
    }
}
