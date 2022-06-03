//
//  ImageViewing.swift
//  shadowpix
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Photos
import Combine

protocol MediaViewingViewModel {
    
    associatedtype SourceType = MediaDescribing
    associatedtype Reader = FileReader
    
    
    var sourceMedia: SourceType { get set }
    var keyManager: KeyManager { get set }
    var fileAccess: Reader { get set }
    
    init(image: SourceType, keyManager: KeyManager)
    
    func decrypt()
}

class ImageViewingViewModel<SourceType: MediaDescribing, Reader: FileReader>: ObservableObject, MediaViewingViewModel {
    @Published var decryptedFileRef: CleartextMedia<Data>?
    var sourceMedia: SourceType
    var keyManager: KeyManager
    var fileAccess: Reader
    private var cancellables = Set<AnyCancellable>()
    required init(image: SourceType, keyManager: KeyManager) {
        self.sourceMedia = image
        self.keyManager = keyManager
        self.fileAccess = Reader(key: keyManager.currentKey)
    }
    
    func decrypt() {
        
            fileAccess.loadMediaInMemory(media: sourceMedia).sink(receiveCompletion: { completion in
                
            }, receiveValue: { decrypted in
                self.decryptedFileRef = decrypted
            }).store(in: &cancellables)
    }
}

struct ImageViewing<M: MediaDescribing, F: FileReader>: View {
    
    
    @ObservedObject var viewModel: ImageViewingViewModel<M, F>
    var body: some View {
        VStack {
            if let imageData = viewModel.decryptedFileRef?.source, let image = UIImage(data: imageData) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text("Could not decrypt image")
                    .foregroundColor(.red)
            }
        }.onAppear {
            self.viewModel.decrypt()
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
