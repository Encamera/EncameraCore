//
//  MediaViewingViewModel.swift
//  Encamera
//
//  Created by Alexander Freas on 13.08.24.
//

import Foundation
import EncameraCore

protocol MediaViewingViewModel: AnyObject {

    associatedtype SourceType: EncryptedMedia

    var sourceMedia: InteractableMedia<SourceType> { get set }
    var fileAccess: FileAccess? { get set }
    var error: MediaViewingError? { get set }
    var delegate: MediaViewingDelegate { get }

    @MainActor
    var decryptedFileRef: InteractableMedia<CleartextMedia>? { get set }
    init(media: InteractableMedia<SourceType>, fileAccess: FileAccess, delegate: MediaViewingDelegate)

    func decrypt() async throws -> InteractableMedia<CleartextMedia>
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
                decryptedFileRef = decrypted
            }

        } catch {

            self.error = .decryptError(wrapped: error)
        }
    }

}
