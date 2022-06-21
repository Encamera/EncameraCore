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
    
    @MainActor
    @Published var decryptProgress: Double = 0.0
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
    
    @MainActor
    func decrypt() async throws -> CleartextMedia<URL> {
        guard let fileAccess = fileAccess else {
            throw MediaViewingError.fileAccessNotAvailable
        }
        return try await fileAccess.loadMediaToURL(media: sourceMedia) { progress in
            self.decryptProgress = progress
        }
    }
}

struct MovieViewing<M: MediaDescribing, F: FileReader>: View where M.MediaSource == URL {
    @State var progress = 0.0
    @ObservedObject var viewModel: MovieViewingViewModel<M, F>
    
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack {
            if let movieUrl = viewModel.decryptedFileRef?.source {
                let player = AVPlayer(url: movieUrl)
                
                VideoPlayer(player: player)
            } else if let error = viewModel.error {
                Text("Could not decrypt movie: \(error.localizedDescription)")
                    .foregroundColor(.red)
            } else {
                ProgressView("Decrypting...", value: progress).onReceive(viewModel.$decryptProgress) { out in
                    self.progress = out
                }.task {
                    await viewModel.decryptAndSet()
                }.padding()
                
            }
        }
        
    }
}
//
struct MovieViewing_Previews: PreviewProvider {
    static var previews: some View {
        MovieViewing<EncryptedMedia, DiskFileAccess<DemoDirectoryModel>>(progress: 20.0, viewModel: .init(media: EncryptedMedia(source: URL(fileURLWithPath: ""),
                                                                            mediaType: .video,
                                                                            id: "234"),
                                                      keyManager: DemoKeyManager(isAuthorized: Just(true).eraseToAnyPublisher())))
    }
}
