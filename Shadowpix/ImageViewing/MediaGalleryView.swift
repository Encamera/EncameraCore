//
//  MediaGalleryView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 10.05.22.
//

import SwiftUI
import Combine

class MediaGalleryViewModel<F: FileAccess, D: DirectoryModel>: ObservableObject {
    @Published var directory: D
    @Published var fileAccess: F
    @Published var key: ImageKey?
    var cancellables = Set<AnyCancellable>()

    init(directory: D, key: ImageKey?) {
        self.directory = directory
        self.key = key
        self.fileAccess = F(key: key)
        
    }
}

struct MediaGalleryView<F: FileAccess, D: DirectoryModel>: View {
    @State var selectedMediaType: MediaType = .photo

    @State var viewModel: MediaGalleryViewModel<F, D>
    @EnvironmentObject var state: ShadowPixState
    
    
    init(viewModel: MediaGalleryViewModel<F, D>) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        let galleryViewModel = GalleryViewModel(sourceDirectory: viewModel.directory, fileAccess: viewModel.fileAccess, keyManager: state.keyManager)
        VStack {
            Picker("Media Type", selection: $selectedMediaType) {
                ForEach(MediaType.displayCases, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedMediaType, perform: { newValue in
                print("selected media type \(newValue)")
                guard let keyName = state.keyManager.currentKey?.name else {
                    return
                }
                print(D(subdirectory: newValue.path, keyName: keyName))
                self.viewModel.directory = D(subdirectory: newValue.path, keyName: keyName)
            })
            GalleryView(viewModel: galleryViewModel)
        }
    }
}

struct MediaGalleryView_Previews: PreviewProvider {

    
    static var previews: some View {
        MediaGalleryView(viewModel: MediaGalleryViewModel<DemoFileEnumerator, DemoDirectoryModel>(directory: DemoDirectoryModel(), key: nil))
            .environmentObject(ShadowPixState())
    }
}
