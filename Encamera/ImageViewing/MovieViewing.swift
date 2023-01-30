//
//  MovieViewing.swift
//  Encamera
//
//  Created by Alexander Freas on 22.11.21.
//

import SwiftUI
import AVKit
import Combine
import EncameraCore

class MovieViewingViewModel<SourceType: MediaDescribing>: ObservableObject, MediaViewingViewModel {
    var fileAccess: FileAccess?
    
    @Published var decryptedFileRef: CleartextMedia<URL>?
    @Binding var isPlaying: Bool
    @MainActor
    @Published var decryptProgress: Double = 0.0
    var error: MediaViewingError?
    
    
    var sourceMedia: SourceType

    required init(media: SourceType, fileAccess: FileAccess) {
        self.sourceMedia = media
        self.fileAccess = fileAccess
        _isPlaying = .constant(false)
    }
    
    convenience init(media: SourceType, fileAccess: FileAccess, isPlaying: Binding<Bool>) {
        self.init(media: media, fileAccess: fileAccess)
        _isPlaying = isPlaying
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

struct MovieViewing<M: MediaDescribing>: View where M.MediaSource == URL {
    @State var progress = 0.0
    @StateObject var viewModel: MovieViewingViewModel<M>
    
    var body: some View {
        VStack {
            
            if let movieUrl = viewModel.decryptedFileRef?.source {
                let player = AVPlayer(url: movieUrl)
                
                VideoPlayer(player: player)
                    .onChange(of: viewModel.isPlaying) { newValue in
                        if newValue == true {
                            player.play()
                        } else {
                            player.pause()
                        }
                    }
            } else if let error = viewModel.error {
                Text(L10n.couldNotDecryptMovie(error.localizedDescription))
                    .foregroundColor(.red)
            } else {
                ProgressView(L10n.decrypting, value: progress).onReceive(viewModel.$decryptProgress) { out in
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
        MovieViewing<EncryptedMedia>(progress: 20.0, viewModel: .init(media: EncryptedMedia(source: URL(fileURLWithPath: ""),
                                                                            mediaType: .video,
                                                                            id: "234"),
                                                      fileAccess: DemoFileEnumerator()))
    }
}
