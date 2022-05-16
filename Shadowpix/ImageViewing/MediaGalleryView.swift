//
//  MediaGalleryView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 10.05.22.
//

import SwiftUI

class MediaGalleryViewModel: ObservableObject {
    @Published var selectedMediaType: MediaType = .photos
}

struct MediaGalleryView: View {
    
    
    
    @State var viewModel: MediaGalleryViewModel
    @State var selectedMediaType: MediaType = .photos
    @EnvironmentObject var state: ShadowPixState
    var fileEnumerator: iCloudFilesEnumerator = iCloudFilesEnumerator()
    
    var body: some View {
        let galleryViewModel = GalleryViewModel(pathInfo: iCloudFilesDirectoryModel(subdirectory: selectedMediaType.path, keyName: state.selectedKey!.name))
        VStack {
            Picker("Media Type", selection: $selectedMediaType) {
                ForEach(MediaType.allCases, id: \.rawValue) { type in
                    Text(type.title).tag(type.rawValue)
                }
            }.pickerStyle(.segmented)
            GalleryView(viewModel: galleryViewModel, fileEnumerator: fileEnumerator)
        }
    }
}

struct MediaGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        MediaGalleryView(viewModel: MediaGalleryViewModel())
            .environmentObject(ShadowPixState.shared)
    }
}
