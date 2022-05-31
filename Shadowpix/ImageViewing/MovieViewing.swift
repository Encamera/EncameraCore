//
//  MovieViewing.swift
//  Shadowpix
//
//  Created by Alexander Freas on 22.11.21.
//

import SwiftUI
import AVKit
import Combine


struct MovieViewing<T: MediaDescribing>: View  where T.MediaSource == URL {
        
    
    class ViewModel: ObservableObject {
        
        var encrypedFileRef: T
        var fileHandler: SecretDiskFileHandler<T>
        private var cancellables = Set<AnyCancellable>()

        @Published var decryptedFileRef: CleartextMedia<URL>?
        
        init(selectedKey: ImageKey, fileRef: T) {
            self.encrypedFileRef = fileRef
            self.fileHandler = SecretDiskFileHandler(keyBytes: selectedKey.keyBytes, source: fileRef)
        }
        
        func decrypt() {
            fileHandler.decryptFile().sink { signal in
                
            } receiveValue: { media in
                self.decryptedFileRef = media
            }.store(in: &cancellables)

        }
        
        
//        func decryptMovie() -> URL? {
//            do {
//                _ = movieUrl.startAccessingSecurityScopedResource()
//                let data = try Data(contentsOf: movieUrl)
//                movieUrl.stopAccessingSecurityScopedResource()
//                guard let decrypted: Data = ChaChaPolyHelpers.decrypt(encryptedContent: data) else {
//                    print("Could not decrypt image")
//                    return nil
//                }
//                let movieUrl = filesManager.createTemporaryMovieUrl()
//                try decrypted.write(to: movieUrl)
//                return movieUrl
//
//            } catch {
//                print("error opening movie", error.localizedDescription)
//                return nil
//            }
//
//        }
        
        
    }
    @ObservedObject var viewModel: ViewModel
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
            viewModel.decrypt()
        }
        
    }
}
//
//struct MovieViewing_Previews: PreviewProvider {
//    static var previews: some View {
//        MovieViewing(viewModel: MovieViewing.ViewModel(selectedKey: ImageKey(name: "", keyBytes: []), fileRef: Encryp))
//    }
//}
