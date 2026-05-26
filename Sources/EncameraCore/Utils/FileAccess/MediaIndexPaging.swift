//
//  MediaIndexPaging.swift
//  EncameraCore
//
//  Sort-aware, offset-based pagination over an in-memory media index. Sorting
//  and filtering operate purely on the cached keys in each `MediaIndexEntry` —
//  no filesystem access and no decryption — so a page is produced in well
//  under a millisecond regardless of album size.
//

import Foundation

/// A materialized page of media plus enough information to request the next one.
public struct MediaPageResult {
    public let media: [InteractableMedia<EncryptedMedia>]
    /// Total number of items after filtering, across all pages.
    public let totalCount: Int
    /// The `offset` to pass when requesting the next page.
    public let nextOffset: Int
    /// Whether any pages remain after this one.
    public var hasMore: Bool { nextOffset < totalCount }

    public init(media: [InteractableMedia<EncryptedMedia>], totalCount: Int, nextOffset: Int) {
        self.media = media
        self.totalCount = totalCount
        self.nextOffset = nextOffset
    }
}

extension MediaIndex {

    /// Entries sorted by `sortOption` and filtered by `filterOptions`.
    func sortedFilteredEntries(
        sortBy sortOption: MediaSortOption,
        filterBy filterOptions: MediaFilterOptions
    ) -> [MediaIndexEntry] {
        let filtered: [MediaIndexEntry]
        if filterOptions == .all {
            filtered = entries
        } else {
            filtered = entries.filter {
                filterOptions.contains(MediaFilterOptions(rawValue: $0.subtypeRawValue))
            }
        }
        return filtered.sorted { Self.isOrderedBefore($0, $1, sortOption: sortOption) }
    }

    /// Mirrors the ordering in `DiskFileAccess.buildMediaWithMetadataArray`:
    /// by the chosen date, with unknown-date items pushed to the end.
    /// Ties on the date key are broken by `id` to guarantee a stable total
    /// order, which offset-based pagination requires.
    private static func isOrderedBefore(
        _ lhs: MediaIndexEntry,
        _ rhs: MediaIndexEntry,
        sortOption: MediaSortOption
    ) -> Bool {
        switch sortOption {
        case .dateTaken(let ascending):
            if lhs.dateTaken == rhs.dateTaken {
                return lhs.id < rhs.id
            }
            return compareDates(lhs.dateTaken, rhs.dateTaken, ascending: ascending)
        case .dateEncrypted(let ascending):
            if lhs.dateEncrypted == rhs.dateEncrypted {
                return lhs.id < rhs.id
            }
            return compareDates(lhs.dateEncrypted, rhs.dateEncrypted, ascending: ascending)
        }
    }

    private static func compareDates(_ lhs: Date?, _ rhs: Date?, ascending: Bool) -> Bool {
        guard let lhs, let rhs else {
            if lhs == nil && rhs == nil { return false }
            return lhs != nil
        }
        return ascending ? lhs < rhs : lhs > rhs
    }
}
