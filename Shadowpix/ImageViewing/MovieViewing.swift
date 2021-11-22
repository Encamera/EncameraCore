//
//  MovieViewing.swift
//  Shadowpix
//
//  Created by Alexander Freas on 22.11.21.
//

import SwiftUI
import AVKit


struct MovieViewing: View {
        
    
    class ViewModel: ObservableObject {
        
        var movieUrl: URL
        var filesManager: TempFilesManager
        
        init(movieUrl: URL, filesManager: TempFilesManager) {
            self.movieUrl = movieUrl
            self.filesManager = filesManager
        }
        
        func decryptMovie() -> URL? {
            do {
                _ = movieUrl.startAccessingSecurityScopedResource()
                let data = try Data(contentsOf: movieUrl)
                movieUrl.stopAccessingSecurityScopedResource()
                guard let decrypted: Data = ChaChaPolyHelpers.decrypt(encryptedContent: data) else {
                    print("Could not decrypt image")
                    return nil
                }
                let movieUrl = filesManager.createTemporaryMovieUrl()
                try decrypted.write(to: movieUrl)
                return movieUrl

            } catch {
                print("error opening movie", error.localizedDescription)
                return nil
            }

        }
        
        
    }
    @ObservedObject var viewModel: ViewModel
    
    var body: some View {
        VStack {
            if let movieUrl = viewModel.decryptMovie() {
                let player = AVPlayer(url: movieUrl)
                VideoPlayer(player: player)
            } else {
                Text("Could not decrypt movie")
                    .foregroundColor(.red)
            }
        }.onDisappear {
            try? viewModel.filesManager.cleanup()
        }
        
    }
}

struct MovieViewing_Previews: PreviewProvider {
    static var previews: some View {
        MovieViewing(viewModel: MovieViewing.ViewModel(movieUrl: URL(string: "https://")!, filesManager: TempFilesManager()))
    }
}
