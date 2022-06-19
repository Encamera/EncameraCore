//
//  MovieViewing.swift
//  Shadowpix
//
//  Created by Alexander Freas on 22.11.21.
//

import SwiftUI
import AVKit
import Combine


class MovieViewingViewModel<SourceType: MediaDescribing, Reader: FileReader>: ObservableObject, MediaViewingViewModel {
    var fileAccess: Reader?
    
    @Published var decryptedFileRef: CleartextMedia<URL>?
    
    var error: MediaViewingError?
    
    
    var sourceMedia: SourceType
    var keyManager: KeyManager

    required init(media: SourceType, keyManager: KeyManager) {
        self.sourceMedia = media
        self.keyManager = keyManager
        if let key = keyManager.currentKey {
            self.fileAccess = Reader(key: key)
        } else {
            self.error = .noKeyAvailable
        }
    }
    
    func decrypt() async throws -> CleartextMedia<URL> {
        guard let fileAccess = fileAccess else {
            throw MediaViewingError.fileAccessNotAvailable
        }
        return try await fileAccess.loadMediaToURL(media: sourceMedia)
    }
}

struct MovieViewing<M: MediaDescribing, F: FileReader>: View where M.MediaSource == URL {
    
    @ObservedObject var viewModel: MovieViewingViewModel<M, F>
    var body: some View {
        VStack {
            if let movieUrl = viewModel.decryptedFileRef?.source {
                let player = AVPlayer(url: movieUrl)
                
                VideoPlayer(player: player)
            } else {
                Text("Could not decrypt movie")
                    .foregroundColor(.red)
            }
        }.onAppear {
            Task {
                await viewModel.decryptAndSet()
            }
        }
        
    }
}
//
//struct MovieViewing_Previews: PreviewProvider {
//    static var previews: some View {
//        MovieViewing(viewModel: MovieViewing.ViewModel(selectedKey: ImageKey(name: "", keyBytes: []), fileRef: Encryp))
//    }
//}
