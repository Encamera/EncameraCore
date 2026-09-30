//
//  ImportSpaceBudget.swift
//  EncameraCore
//

import Foundation

/// Whether an import selection fits in free space, and how much of it does.
public struct ImportSpaceVerdict: Equatable, Sendable {
    /// Bytes the known-size items need, including overhead and headroom.
    public let requiredBytes: Int64
    public let freeBytes: Int64?
    /// Items whose size couldn't be known before loading.
    public let unknownCount: Int
    /// The longest prefix of the selection, in order, that fits.
    public let fitsCount: Int
    public let totalCount: Int
    public let fitsAll: Bool
}

/// Turns per-item sizes and free space into an `ImportSpaceVerdict`.
///
/// An item needs its ciphertext (about its plaintext size) plus an encrypted
/// thumbnail. The import also holds one item's cleartext temp copy at a time,
/// so the largest item is counted once more, and `reserveBytes` is never used.
/// CloudKit albums need the same space: their ciphertext stays on the device
/// until it uploads.
public enum ImportSpaceBudget {
    public static let ciphertextOverheadFactor = 1.01
    public static let perItemThumbnailAllowance: Int64 = 64 * 1024
    public static let reserveBytes: Int64 = 500 * 1024 * 1024

    /// The bytes one item needs once stored, excluding transient headroom.
    public static func storedBytes(forItemOfSize size: Int64) -> Int64 {
        Int64((Double(size) * ciphertextOverheadFactor).rounded(.up)) + perItemThumbnailAllowance
    }

    public static func evaluate(itemSizes: [Int64?], freeBytes: Int64?) -> ImportSpaceVerdict {
        let unknownCount = itemSizes.filter { $0 == nil }.count
        let allowance = freeBytes.map { $0 - reserveBytes }

        var stored: Int64 = 0
        var largest: Int64 = 0
        var fitsCount = 0
        var stillFitting = true
        for size in itemSizes {
            if let size {
                stored += storedBytes(forItemOfSize: size)
                largest = max(largest, size)
            }
            if stillFitting, let allowance, stored + largest > allowance {
                stillFitting = false
            }
            if stillFitting {
                fitsCount += 1
            }
        }
        let requiredBytes = stored + largest

        let canJudge = allowance != nil && unknownCount < itemSizes.count
        let fitsAll = !canJudge || fitsCount == itemSizes.count
        return ImportSpaceVerdict(
            requiredBytes: requiredBytes,
            freeBytes: freeBytes,
            unknownCount: unknownCount,
            fitsCount: fitsAll ? itemSizes.count : fitsCount,
            totalCount: itemSizes.count,
            fitsAll: fitsAll
        )
    }
}
