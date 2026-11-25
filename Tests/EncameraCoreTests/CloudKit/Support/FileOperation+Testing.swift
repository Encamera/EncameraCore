//
//  FileOperation+Testing.swift
//  EncameraCoreTests
//

@testable import EncameraCore

extension FileOperation {
    /// The ids a create or a batch of creates names, in order; empty otherwise.
    var createdMediaIDs: [String] {
        switch self {
        case .create(let media): return [media.id]
        case .createBatch(let media, _): return media.map(\.id)
        case .delete, .move, .albumCoverChanged: return []
        }
    }
}
