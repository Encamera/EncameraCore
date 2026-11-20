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
        return filtered.sorted {
            MediaSorter.isOrderedBefore(($0.id, $0.sortKeys), ($1.id, $1.sortKeys), by: sortOption)
        }
    }
}
