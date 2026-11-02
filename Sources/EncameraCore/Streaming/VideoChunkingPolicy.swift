//
//  VideoChunkingPolicy.swift
//  EncameraCore
//
//  The single place the ENC2/ENC3 write decision is made. Every plaintext byte
//  in the product becomes ciphertext in exactly two chokepoints —
//  `DiskFileAccess.save` and `CloudKitFileAccess.saveSingle` — and both ask this
//  policy, so the rule cannot drift between them.
//

import Foundation

public enum VideoChunkingPolicy {

    /// The one rule: `mediaType == .video` AND plaintext size ≥ the ENC3
    /// threshold AND the album's backend supports ENC3. Photos, Live Photo movie
    /// components (~2-4 MB), and small videos are untouched by construction.
    public static func shouldWriteSeekableFormat(mediaType: MediaType,
                                                 plaintextLength: Int64,
                                                 storageType: StorageType?) -> Bool {
        guard mediaType == .video else { return false }
        guard plaintextLength >= Int64(SeekableEncryptedFormat.threshold) else { return false }
        switch storageType {
        case .local, .cloudKit:
            return true
        case .icloud, .none:
            // iCloud Drive syncs files across devices, so an ENC3 file written by
            // this version would be unreadable by an older app version on another
            // device. The storage type is deprecated; keep writing ENC2 there and
            // let the deprecation path retire the problem.
            return false
        }
    }
}
