//
//  MediaViewingError.swift
//  Encamera
//
//  Created by Alexander Freas on 13.08.24.
//

import Foundation
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
