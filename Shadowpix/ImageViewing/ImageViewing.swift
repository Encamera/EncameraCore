//
//  ImageViewing.swift
//  shadowpix
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Photos
import Combine

struct ImageViewing<M: MediaDescribing, F: FileReader>: View {
    
    class ViewModel: ObservableObject {
        @Published var cleartextImage: CleartextMedia<Data>?
        var sourceImage: M
        var state: ShadowPixState
        var fileAccess: F
        private var cancellables = Set<AnyCancellable>()
        init(image: M, state: ShadowPixState) {
            self.sourceImage = image
            self.state = state
            self.fileAccess = F(key: state.selectedKey)
        }
        
        func decryptImage() {
            fileAccess.loadMedia(media: sourceImage).sink(receiveCompletion: { completion in
                
            }, receiveValue: { media in
                self.cleartextImage = media
            }).store(in: &cancellables)
        }
    }
    @ObservedObject var viewModel: ViewModel
    var body: some View {
        VStack {
            if let imageData = viewModel.cleartextImage?.source,   viewModel.state.isAuthorized, let image = UIImage(data: imageData) {
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
