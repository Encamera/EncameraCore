//
//  AsyncImage.swift
//  Encamera
//
//  Created by Alexander Freas on 17.06.22.
//

import Combine
import SwiftUI

struct AsyncImage<Placeholder: View, T: MediaDescribing>: View, Identifiable where T.MediaSource == URL {
    
    @MainActor
    class ViewModel: ObservableObject {
        private var loader: FileReader
        private var targetMedia: T
        @Published var cleartextMedia: PreviewModel?
        @Published var error: Error?
        
        init(targetMedia: T, loader: FileReader) {
            self.targetMedia = targetMedia
            self.loader = loader
        }
        
        func loadPreview() async {
            do {
                let preview = try await loader.loadMediaPreview(for: targetMedia)
                await MainActor.run {
                    cleartextMedia = preview
                }
            } catch {
                self.error = SecretFilesError.sourceFileAccessError
            }
        }
    }
    var id: String = NSUUID().uuidString
    
    @StateObject var viewModel: ViewModel
    var placeholder: Placeholder
    
    var body: some View {
        if let decrypted = viewModel.cleartextMedia?.thumbnailMedia.source,
           let image = UIImage(data: decrypted) {
            ZStack {
                Color.clear
                    .background {
                        
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .aspectRatio(contentMode:.fill)
                    .clipped()
                    .contentShape(Rectangle())

                
                
                if let duration = viewModel.cleartextMedia?.videoDuration {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(duration)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(2.0)
                        }
                        
                    }
                }
            }                    

        } else if viewModel.error != nil {
            Image(systemName: "x.square")
                .foregroundColor(.white)
        
        } else {
            placeholder.task {
                await viewModel.loadPreview()
            }
        }
    }
}

struct AsyncImage_Previews: PreviewProvider {
    
    static var previews: some View {
        
        GalleryGridView(viewModel: GalleryGridViewModel(privateKey: DemoPrivateKey.dummyKey()))
    }
}
