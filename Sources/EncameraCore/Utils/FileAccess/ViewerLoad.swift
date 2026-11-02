//
//  ViewerLoad.swift
//  EncameraCore
//
//  Marks the reads the viewer and player make while they open media, so a read
//  can tell an open in the lightbox apart from a grid thumbnail, a share, an
//  export or an edit.
//

import Foundation

public enum ViewerLoad {
    /// True for every read made inside `loadMediaForViewer` or
    /// `loadMediaToURLsForViewer`, false for every other read.
    @TaskLocal public static var isActive = false
}

public extension FileReader {

    /// `loadMedia` for the viewer or player: every read it makes sees
    /// `ViewerLoad.isActive`.
    func loadMediaForViewer<T: MediaDescribing>(media: InteractableMedia<T>,
                                                progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> {
        try await ViewerLoad.$isActive.withValue(true) {
            try await loadMedia(media: media, progress: progress)
        }
    }

    /// `loadMediaToURLs` for the player: every read it makes sees
    /// `ViewerLoad.isActive`.
    func loadMediaToURLsForViewer(media: InteractableMedia<EncryptedMedia>,
                                  progress: @escaping (FileLoadingStatus) -> Void) async throws -> [URL] {
        try await ViewerLoad.$isActive.withValue(true) {
            try await loadMediaToURLs(media: media, progress: progress)
        }
    }
}
