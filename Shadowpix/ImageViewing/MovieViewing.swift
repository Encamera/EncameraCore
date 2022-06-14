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
    @Published var decryptedFileRef: CleartextMedia<URL>?
    var sourceMedia: SourceType
    var keyManager: KeyManager
    var fileAccess: Reader
    private var cancellables = Set<AnyCancellable>()
    required init(image: SourceType, keyManager: KeyManager) {
        self.sourceMedia = image
        self.keyManager = keyManager
        self.fileAccess = Reader(key: keyManager.currentKey)
    }
    
    func decrypt() async {
        do {
            decryptedFileRef = try await fileAccess.loadMediaToURL(media: sourceMedia)
        } catch {
            print(error)
        }
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
                await viewModel.decrypt()
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
