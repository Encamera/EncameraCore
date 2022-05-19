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

struct MediaGalleryView<Enumerator: FileEnumerator>: View {
    
    @State var viewModel: MediaGalleryViewModel
    @State var selectedMediaType: MediaType = .photos
    @EnvironmentObject var state: ShadowPixState
    @State var fileEnumerator: Enumerator
    
    var body: some View {
        let galleryViewModel = GalleryViewModel(fileEnumerator: fileEnumerator)
        VStack {
            Picker("Media Type", selection: $selectedMediaType) {
                ForEach(MediaType.allCases, id: \.rawValue) { type in
                    Text(type.title).tag(type.rawValue)
                }
            }.pickerStyle(.segmented)
                .onChange(of: selectedMediaType) { newValue in
                    let directoryModel = Enumerator.DirModel(subdirectory: newValue.path, keyName: "")
                    self.fileEnumerator = Enumerator(directoryModel: directoryModel)
                }
            GalleryView(viewModel: galleryViewModel)
        }
    }
}

struct MediaGalleryView_Previews: PreviewProvider {
    
    private class DemoFileEnumerator: FileEnumerator {
        func loadMediaPreview(for media: ShadowPixMedia) {
            media.decryptedImage = DecryptedImage(image: UIImage(systemName: "photo.fill")!)
        }
        
        required init(directoryModel: DemoDirectoryModel) {
            
        }
        
        
        func enumerateImages(completion: ([ShadowPixMedia]) -> Void) {
            completion((0...10).map { _ in
                ShadowPixMedia(url: URL(fileURLWithPath: ""))
            })
            
        }
    }
    
    private class DemoDirectoryModel: DirectoryModel {
        required init(subdirectory: String = "", keyName: String = "") {
            
        }
        
        let subdirectory = ""
        let keyName = ""
        
        var driveURL: URL {
            URL(fileURLWithPath: "")
        }
    }
    
    static var previews: some View {
        MediaGalleryView(viewModel: MediaGalleryViewModel(), fileEnumerator: DemoFileEnumerator(directoryModel: DemoDirectoryModel()))
            .environmentObject(ShadowPixState.shared)
    }
}
