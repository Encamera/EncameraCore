//
//  ImageViewing.swift
//  shadowpix
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Photos
import Combine

enum MediaViewingError: Error {
    case noKeyAvailable
    case fileAccessNotAvailable
    case decryptError(wrapped: Error)
}

protocol MediaViewingViewModel: AnyObject {
    
    associatedtype SourceType = MediaDescribing
    associatedtype TargetT: MediaSourcing
    associatedtype Reader: FileReader
    
    
    var sourceMedia: SourceType { get set }
    var keyManager: KeyManager { get set }
    var fileAccess: Reader? { get set }
    var error: MediaViewingError? { get set }

    var decryptedFileRef: CleartextMedia<TargetT>? { get set }
    init(media: SourceType, keyManager: KeyManager)
    
    func decrypt() async throws -> CleartextMedia<TargetT>
}

extension MediaViewingViewModel {
    @MainActor
    func decryptAndSet() async {
        do {
            self.decryptedFileRef = try await decrypt()
        } catch {
            self.error = .decryptError(wrapped: error)
        }
    }
}

class ImageViewingViewModel<SourceType: MediaDescribing, Reader: FileReader>: ObservableObject, MediaViewingViewModel {
    @Published var decryptedFileRef: CleartextMedia<Data>?
    var sourceMedia: SourceType
    var keyManager: KeyManager
    var fileAccess: Reader?
    var error: MediaViewingError?

    required init(media: SourceType, keyManager: KeyManager) {
        self.sourceMedia = media
        self.keyManager = keyManager
        if let key = keyManager.currentKey {
            self.fileAccess = Reader(key: key)
        } else {
            self.error = .noKeyAvailable
        }
    }
    
    func decrypt() async throws -> CleartextMedia<Data> {
        guard let fileAccess = fileAccess else {
            throw MediaViewingError.fileAccessNotAvailable
        }
        return try await fileAccess.loadMediaInMemory(media: sourceMedia)
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
            Task {
                await viewModel.decryptAndSet()
            }
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
