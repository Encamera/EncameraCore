//
//  AsyncImage.swift
//  Shadowpix
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
        private var cancellables = Set<AnyCancellable>()
        @Published var cleartextMedia: PreviewModel?
        
        init(targetMedia: T, loader: FileReader) {
            self.targetMedia = targetMedia
            self.loader = loader
        }
        
        func loadPreview() async {
            do {
                cleartextMedia = try await loader.loadMediaPreview(for: targetMedia)
            } catch {
                print(error)
            }
        }
    }
    var id: String = NSUUID().uuidString
    private var placeholder: Placeholder
    @ObservedObject private var viewModel: ViewModel
    
    init(viewModel: ViewModel, placeholder: () -> Placeholder) {
        self.viewModel = viewModel
        self.placeholder = placeholder()
    }
    
    
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .local)
            let side = frame.height
            content
            .scaledToFill()
            .position(x: frame.midX, y: frame.midY)
            .frame(width: side, height: side)
        }
    }
    
    @ViewBuilder private var content: some View {
        // need separate view for holding preview
        if let decrypted = viewModel.cleartextMedia?.thumbnailMedia.source, let image = UIImage(data: decrypted) {
            Image(uiImage: image)
                .resizable()
                .clipped()
                .aspectRatio(contentMode:.fit)
        } else {
            placeholder.task {
                await viewModel.loadPreview()
            }
        }
    }
}
