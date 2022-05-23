//
//  ImageViewing.swift
//  shadowpix
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Photos
import Combine

struct ImageViewing: View {
    
    class ViewModel: ObservableObject {
        @Published var image: MediaDescribing
        var state: ShadowPixState
        private var cancellables = Set<AnyCancellable>()
        init(image: EncryptedMedia, state: ShadowPixState) {
            self.image = image
            self.state = state
        }
        
        func decryptImage() {
            state.fileHandler?.loadMedia(media: image).sink { media in
                self.image = media
            }.store(in: &cancellables)
        }
    }
    @ObservedObject var viewModel: ViewModel
    var body: some View {
        VStack {
            if let imageData = viewModel.image.data,  viewModel.state.isAuthorized, let image = UIImage(data: imageData) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text("Could not decrypt image")
                    .foregroundColor(.red)
            }
        }.onAppear {
            self.viewModel.decryptImage()
        }
    }
}

//struct ImageViewing_Previews: PreviewProvider {
//    static var previews: some View {
//        ImageViewing(viewModel: ImageViewing.ViewModel(image: ShadowPixMedia(url: Bundle.main.url(forResource: "shadowimage.shdwpic", withExtension: nil)!)))
//            .environmentObject(ShadowPixState(fileHandler: DemoFileEnumerator()))
//    }
//    
//}
