//
//  ImageViewing.swift
//  encamera
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Combine
import PDFKit

enum MediaViewingError: ErrorDescribable {
    case noKeyAvailable
    case fileAccessNotAvailable
    case decryptError(wrapped: Error)
    
    var displayDescription: String {
        switch self {
        case .noKeyAvailable:
            return "No key available."
        case .fileAccessNotAvailable:
            return "No file access available."
        case .decryptError(let wrapped as ErrorDescribable):
            return "Decryption error: \(wrapped.displayDescription)"
        case .decryptError(wrapped: let wrapped):
            return "Decryption error: \(wrapped.localizedDescription)"
        }
    }
}

protocol MediaViewingViewModel: AnyObject {
    
    associatedtype SourceType = MediaDescribing
    associatedtype TargetT: MediaSourcing
    
    var sourceMedia: SourceType { get set }
    var fileAccess: FileAccess? { get set }
    var error: MediaViewingError? { get set }
    
    var decryptedFileRef: CleartextMedia<TargetT>? { get set }
    init(media: SourceType, fileAccess: FileAccess)
    
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

class ImageViewingViewModel<SourceType: MediaDescribing>: ObservableObject {
    
    @Published var decryptedFileRef: CleartextMedia<Data>?
    var sourceMedia: SourceType
    var fileAccess: FileAccess?
    var error: MediaViewingError?
    
    required init(media: SourceType, fileAccess: FileAccess) {
        self.sourceMedia = media
        self.fileAccess = fileAccess
    }
    
    func decryptAndSet() {
        Task {
            do {
                let result = try await fileAccess!.loadMediaInMemory(media: sourceMedia) { progress in
                    
                }
                await MainActor.run {
                    self.decryptedFileRef = result
                }
                
            } catch {
                self.error = .decryptError(wrapped: error)
            }
        }
    }
    
}

struct ImageViewing<M: MediaDescribing>: View {
    
    @Binding var currentScale: CGFloat
    @Binding var finalOffset: CGSize
    @State var currentOffset: CGSize = .zero
    @State var showBottomActions = false
    @StateObject var viewModel: ImageViewingViewModel<M>
    var externalGesture: DragGesture
    var cancellables = Set<AnyCancellable>()
    
    
    var body: some View {
        
        ZStack {
            if let imageData = viewModel.decryptedFileRef?.source,
               let image = UIImage(data: imageData) {
                
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(currentScale)
                    .offset(
                        x: finalOffset.width + currentOffset.width,
                        y: finalOffset.height + currentOffset.height
                    )
                    .animation(.easeInOut, value: currentScale)
                    .animation(.easeInOut, value: finalOffset)
                    .zIndex(1)
                
            } else if let error = viewModel.error {
                DecryptErrorExplanation(error: error)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            viewModel.decryptAndSet()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ImageViewing_Previews: PreviewProvider {
    
    
    static var previews: some View {
        NavigationView {
            let url = Bundle.main.url(forResource: "image", withExtension: "jpg")!
            ImageViewing(currentScale: .constant(1.0), finalOffset: .constant(.zero), viewModel: .init(media: EncryptedMedia(source: url)!, fileAccess: DemoFileEnumerator()), externalGesture: DragGesture())
        }
    }
}
