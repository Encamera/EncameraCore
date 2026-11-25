//
//  FileOperationBus.swift
//  Encamera
//
//  Created by Alexander Freas on 17.09.22.
//

import Foundation
import Combine


public enum FileOperation {
    /// One item created by a user action: a capture, an import or an edit.
    case create(EncryptedMedia)
    /// Every item one pass created or changed in one album: a CloudKit sync or
    /// an iCloud Drive folder scan. `albumID` is the CloudKit album's id.
    case createBatch([EncryptedMedia], albumID: String)
    case delete([EncryptedMedia])
    case move(from: [EncryptedMedia], to: Album)
    case albumCoverChanged

    /// True for a batch in an album other than the one with `albumID`, which a
    /// view showing that album can ignore. Every other operation may concern it.
    public func isBatchForAnotherAlbum(than albumID: String?) -> Bool {
        guard case .createBatch(_, let batchAlbumID) = self else { return false }
        return batchAlbumID != albumID
    }
}

/// Reference-typed backing for `FileOperationBus.isSuppressed` so the flag is
/// shared across the value-type copies the bus is accessed through.
private final class FileOperationSuppressionBox {
    var isSuppressed = false
}


public struct FileOperationBus {

    public static var shared: FileOperationBus = FileOperationBus()

    public var operations: AnyPublisher<FileOperation, Never> {
        operationSubject.share().eraseToAnyPublisher()
    }

    private var operationSubject: PassthroughSubject<FileOperation, Never> = PassthroughSubject()
    private let suppressionBox = FileOperationSuppressionBox()

    /// When `true`, `didCreate`/`didDelete`/`didMove` drop their events instead
    /// of publishing them. Each event triggers a full album-grid and gallery
    /// refresh, so a bulk operation that emits one event per item is O(n²).
    /// Suppress for the duration of the batch, then emit a single coalesced
    /// event so subscribers refresh exactly once.
    public var isSuppressed: Bool {
        get { suppressionBox.isSuppressed }
        nonmutating set { suppressionBox.isSuppressed = newValue }
    }

    public func didCreate(_ media: EncryptedMedia) {
        guard !suppressionBox.isSuppressed else { return }
        operationSubject.send(.create(media))
    }

    /// Posts what one pass created or changed in one album as a single event,
    /// so subscribers refresh once per album rather than once per item.
    public func didCreate(_ media: [EncryptedMedia], albumID: String) {
        guard !suppressionBox.isSuppressed, !media.isEmpty else { return }
        operationSubject.send(.createBatch(media, albumID: albumID))
    }

    public func didDelete(_ media: [EncryptedMedia]) {
        guard !suppressionBox.isSuppressed else { return }
        operationSubject.send(.delete(media))
    }

    public func didMove(_ media: [EncryptedMedia], to album: Album) {
        guard !suppressionBox.isSuppressed else { return }
        operationSubject.send(.move(from: media, to: album))
    }

    public func albumCoverChanged() {
        operationSubject.send(.albumCoverChanged)
    }
}
