//
//  ImageViewing.swift
//  encamera
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Combine
import EncameraCore

enum MediaViewingError: ErrorDescribable {
    case noKeyAvailable
    case fileAccessNotAvailable
    case decryptError(wrapped: Error)
    
    var displayDescription: String {
        switch self {
        case .noKeyAvailable:
            return L10n.noKeyAvailable
        case .fileAccessNotAvailable:
            return L10n.noFileAccessAvailable
        case .decryptError(let wrapped as ErrorDescribable):
            return L10n.decryptionError(wrapped.displayDescription)
        case .decryptError(wrapped: let wrapped):
            return L10n.decryptionError(wrapped.localizedDescription)
        }
    }
}

protocol MediaViewingViewModel: AnyObject {
    
    associatedtype SourceType = MediaDescribing
    associatedtype TargetT: MediaSourcing
    
    var sourceMedia: SourceType { get set }
    var fileAccess: FileAccess? { get set }
    var error: MediaViewingError? { get set }
    
    @MainActor
    var decryptedFileRef: CleartextMedia<TargetT>? { get set }
    init(media: SourceType, fileAccess: FileAccess)
    
    func decrypt() async throws -> CleartextMedia<TargetT>
}

extension MediaViewingViewModel {
    func decryptAndSet() async {
        guard await decryptedFileRef == nil else {
            debugPrint("decryptAndSet: not decrypting because we already have a ref")
            return
        }
        do {
            let decrypted = try await decrypt()
            await MainActor.run {
                self.decryptedFileRef = decrypted
            }
            
        } catch {
            
            self.error = .decryptError(wrapped: error)
        }
    }
    
}

class ImageViewingViewModel<SourceType: MediaDescribing>: ObservableObject {
    
    @Published var decryptedFileRef: CleartextMedia<Data>?
    @Published var loadingProgress: Double = 0.0
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
                    self.loadingProgress = progress
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
            EventTracking.trackImageViewed()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ImageViewing_Previews: PreviewProvider {
    
    
    static var previews: some View {
        NavigationView {
            let url = Bundle.main.url(forResource: "1", withExtension: "JPG")!
            ImageViewing(currentScale: .constant(1.0), finalOffset: .constant(.zero), viewModel: .init(media: EncryptedMedia(source: url)!, fileAccess: DemoFileEnumerator()), externalGesture: DragGesture())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
