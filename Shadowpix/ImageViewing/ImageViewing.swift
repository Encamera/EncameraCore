//
//  ImageViewing.swift
//  shadowpix
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Photos
import Combine

enum MediaViewingError: Error {
    case noKeyAvailable
    case fileAccessNotAvailable
    case decryptError(wrapped: Error)
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
    
    func cleanup() {
        do {
            try decryptedFileRef?.delete()
        } catch {
            print("Could not delete file ref \(error)")
        }
    }
}

class ImageViewingViewModel<SourceType: MediaDescribing>: ObservableObject, MediaViewingViewModel {
    @Published var decryptedFileRef: CleartextMedia<Data>?
    var sourceMedia: SourceType
    var fileAccess: FileAccess?
    var error: MediaViewingError?

    required init(media: SourceType, fileAccess: FileAccess) {
        self.sourceMedia = media
        self.fileAccess = fileAccess
    }
    
    func decrypt() async throws -> CleartextMedia<Data> {
        guard let fileAccess = fileAccess else {
            throw MediaViewingError.fileAccessNotAvailable
        }
        return try await fileAccess.loadMediaInMemory(media: sourceMedia) { progress in
            
        }
    }
}

struct ImageViewing<M: MediaDescribing>: View {
    
    
    @ObservedObject var viewModel: ImageViewingViewModel<M>
    var body: some View {
        VStack {
            if let imageData = viewModel.decryptedFileRef?.source, let image = UIImage(data: imageData) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text("Could not decrypt image")
                    .foregroundColor(.red)
            }
        }.onAppear {
            Task {
                await viewModel.decryptAndSet()
            }
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }
}

