//
//  MediaSortKeys.swift
//  EncameraCore
//
//  The values a media item is sorted and filtered by, and the one comparator
//  every listing orders them with.
//

import Foundation

/// The dates and subtype one media item is sorted and filtered by, and where
/// they were read from.
public struct MediaSortKeys: Equatable, Sendable {

    /// Where the keys were read from.
    public enum Source: Equatable, Sendable {
        /// The metadata encrypted into the file itself.
        case encryptedMetadata
        /// The fields of a CloudKit record.
        case recordFields
        /// The file system's attributes, for files without encrypted metadata.
        case fileAttributes
    }

    /// When the media was added to Encamera. Sorts "Date Added".
    public var dateAdded: Date?
    /// When the media was captured, or the date added when that is unknown.
    /// Sorts "Date Taken".
    public var dateTaken: Date?
    /// The filter subtype of the item.
    public var subtype: MediaFilterOptions
    /// Where these keys were read from.
    public var source: Source

    public init(dateAdded: Date?, dateTaken: Date?, subtype: MediaFilterOptions, source: Source) {
        self.dateAdded = dateAdded
        self.dateTaken = dateTaken
        self.subtype = subtype
        self.source = source
    }

    /// Keys read from a file's encrypted metadata. A Live Photo filters as a
    /// still, a video as a video, a screenshot as a screenshot and anything
    /// else as a still. `componentType` is the type of the file the metadata
    /// came from; the metadata's own fields decide the subtype.
    public init(metadata: EncryptedFileMetadata, componentType: MediaType) {
        let subtype: MediaFilterOptions
        if metadata.contentAnalysis?.isLivePhoto == true || metadata.originalMediaType == "livePhoto" {
            subtype = .stillImage
        } else if metadata.originalMediaType == "video" {
            subtype = .video
        } else if metadata.contentAnalysis?.isScreenshot == true {
            subtype = .screenshot
        } else {
            subtype = .stillImage
        }
        self.init(dateAdded: metadata.encryptionDate,
                  dateTaken: metadata.captureDate ?? metadata.encryptionDate,
                  subtype: subtype,
                  source: .encryptedMetadata)
    }

    /// Keys for a CloudKit component record, which carries one date: its
    /// `createdAt` stands in for both dates, and the component's type gives
    /// the subtype.
    public init(recordCreatedAt: Date?, componentType: MediaType) {
        self.init(dateAdded: recordCreatedAt,
                  dateTaken: recordCreatedAt,
                  subtype: MediaIndexEntry.subtype(forComponent: componentType),
                  source: .recordFields)
    }

    /// Keys for a file without encrypted metadata: its creation date stands in
    /// for both dates, and the component's type gives the subtype.
    public init(fileCreationDate: Date?, componentType: MediaType) {
        self.init(dateAdded: fileCreationDate,
                  dateTaken: fileCreationDate,
                  subtype: MediaIndexEntry.subtype(forComponent: componentType),
                  source: .fileAttributes)
    }
}

/// The one ordering every media listing uses.
public enum MediaSorter {

    /// Whether `lhs` sorts before `rhs`: by the chosen date, with items whose
    /// date is unknown after every dated item in both directions. Ties on the
    /// date are broken by `id`, giving the stable total order offset-based
    /// paging requires.
    public static func isOrderedBefore(
        _ lhs: (id: String, keys: MediaSortKeys),
        _ rhs: (id: String, keys: MediaSortKeys),
        by sortOption: MediaSortOption
    ) -> Bool {
        switch sortOption {
        case .dateTaken(let ascending):
            if lhs.keys.dateTaken == rhs.keys.dateTaken {
                return lhs.id < rhs.id
            }
            return compareDates(lhs.keys.dateTaken, rhs.keys.dateTaken, ascending: ascending)
        case .dateEncrypted(let ascending):
            if lhs.keys.dateAdded == rhs.keys.dateAdded {
                return lhs.id < rhs.id
            }
            return compareDates(lhs.keys.dateAdded, rhs.keys.dateAdded, ascending: ascending)
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
