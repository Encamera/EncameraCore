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

class MovieViewingViewModel: ObservableObject, MediaViewingViewModel {
    var fileAccess: FileAccess?
    
    @Published var decryptedFileRef: InteractableMedia<CleartextMedia>?
    @MainActor
    @Published var decryptProgress: FileLoadingStatus = .notLoaded
    @Published var player: AVPlayer?


    var error: MediaViewingError?
    
    
    var sourceMedia: InteractableMedia<EncryptedMedia>
    var delegate: MediaViewingDelegate

    required init(media: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, delegate: MediaViewingDelegate) {
        self.sourceMedia = media
        self.fileAccess = fileAccess
        self.delegate = delegate
    }

    private var durationObservation: NSKeyValueObservation?

    func decrypt() async throws -> InteractableMedia<CleartextMedia> {
        guard let fileAccess = fileAccess else {
            debugPrint("File access not available")
            throw MediaViewingError.fileAccessNotAvailable
        }
        let cleartextMedia = try await fileAccess.loadMedia(media: sourceMedia) { progress in
            debugPrint("Decrypting movie: \(progress)")
            Task { @MainActor in
                self.decryptProgress = progress
            }
        }

        guard cleartextMedia.videoURL != nil else {
            throw MediaViewingError.decryptError(wrapped: NSError(domain: "No URL", code: 0, userInfo: nil))
        }
        return cleartextMedia
        
    }

    
    func decryptAndSet() async {
        guard await decryptedFileRef == nil else {
            debugPrint("decryptAndSet: not decrypting because we already have a ref")
            return
        }
        do {
            let decrypted = try await decrypt()
            await MainActor.run {
                decryptedFileRef = decrypted
                delegate.didView(media: sourceMedia)
            }

        } catch {

            self.error = .decryptError(wrapped: error)
        }
    }
}
