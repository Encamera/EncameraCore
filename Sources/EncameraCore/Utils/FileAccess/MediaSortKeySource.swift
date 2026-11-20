//
//  MediaSortKeySource.swift
//  EncameraCore
//
//  Where a media item's sort keys are read from: the sources that can supply
//  them, and the resolver that asks them in order.
//

import Foundation

/// What a `MediaSortKeySource` is asked about: one component of one media item,
/// with whichever of its local file and CloudKit record are at hand.
public struct MediaSortKeyRequest: Sendable {
    public let mediaID: String
    /// The type of the component the keys are for.
    public let componentType: MediaType
    /// The component's local ciphertext, if there is one.
    public let fileURL: URL?
    /// The component's CloudKit record, if there is one.
    public let record: CloudKitMediaRecordDescriptor?

    public init(mediaID: String,
                componentType: MediaType,
                fileURL: URL? = nil,
                record: CloudKitMediaRecordDescriptor? = nil) {
        self.mediaID = mediaID
        self.componentType = componentType
        self.fileURL = fileURL
        self.record = record
    }
}

/// One place a media item's sort keys can be read from. A source answers nil
/// when it has nothing for the item; the keys it returns may still leave a
/// date nil, or the subtype empty, for a later source to fill.
public protocol MediaSortKeySource: Sendable {
    func sortKeys(for request: MediaSortKeyRequest) async -> MediaSortKeys?
}

/// Asks its sources in order and fills each value from the first source that
/// has it:
///
/// - `dateAdded` and `dateTaken` each come from the first source with a date
///   for them. A source whose metadata has no dates still supplies the subtype,
///   and its dates come from the next source.
/// - `subtype` comes from the first source with a non-empty subtype, and from
///   the component type when none has one.
/// - `source` names the source that supplied `dateAdded`, and is
///   `.fileAttributes` when none did.
///
/// Sources after the one that completes all three values are never asked.
public struct MediaSortKeyResolver: Sendable, DebugPrintable {

    private let sources: [MediaSortKeySource]

    public init(sources: [MediaSortKeySource]) {
        self.sources = sources
    }

    /// The resolver every index builder that reads a file uses. Its order:
    ///
    /// 1. The metadata encrypted into the CloudKit record (to be added ahead of
    ///    the others).
    /// 2. The metadata encrypted into the local file.
    /// 3. The CloudKit record's plaintext fields.
    /// 4. The local file's attributes.
    public static func standard(keyBytes: [UInt8]?) -> MediaSortKeyResolver {
        MediaSortKeyResolver(sources: [
            FileMetadataSortKeySource(keyBytes: keyBytes),
            CloudKitRecordFieldsSortKeySource(),
            FileAttributesSortKeySource(),
        ])
    }

    public func sortKeys(for request: MediaSortKeyRequest) async -> MediaSortKeys {
        var dateAdded: Date?
        var dateTaken: Date?
        var subtype: MediaFilterOptions?
        var dateAddedSource: MediaSortKeys.Source?
        for source in sources {
            if dateAdded != nil, dateTaken != nil, subtype != nil { break }
            guard let answer = await source.sortKeys(for: request) else { continue }
            if dateAdded == nil, let answerDateAdded = answer.dateAdded {
                dateAdded = answerDateAdded
                dateAddedSource = answer.source
            }
            if dateTaken == nil {
                dateTaken = answer.dateTaken
            }
            if subtype == nil, !answer.subtype.isEmpty {
                subtype = answer.subtype
            }
        }
        let keys = MediaSortKeys(dateAdded: dateAdded,
                                 dateTaken: dateTaken,
                                 subtype: subtype ?? MediaIndexEntry.subtype(forComponent: request.componentType),
                                 source: dateAddedSource ?? .fileAttributes)
        logSortKeySource(of: keys, mediaID: request.mediaID)
        return keys
    }

    /// Logs which source supplied an item's keys, without the dates.
    private func logSortKeySource(of keys: MediaSortKeys, mediaID: String) {
        printDebug("sort keys mediaID=\(mediaID) source=\(keys.source)")
    }
}

/// Reads the metadata encrypted into the local file. Answers nil without a
/// key or a file, for a V1 file, which has no metadata, and for an iCloud
/// placeholder, which is not read.
public struct FileMetadataSortKeySource: MediaSortKeySource {

    private let keyBytes: [UInt8]?

    public init(keyBytes: [UInt8]?) {
        self.keyBytes = keyBytes
    }

    public func sortKeys(for request: MediaSortKeyRequest) async -> MediaSortKeys? {
        guard let keyBytes, let fileURL = request.fileURL else { return nil }
        guard let metadata = try? await EncryptedMetadataHandler().readMetadata(from: fileURL, keyBytes: keyBytes) else {
            return nil
        }
        return MediaSortKeys(metadata: metadata, componentType: request.componentType)
    }
}

/// Reads the CloudKit record's plaintext `createdAt`, which stands in for both
/// dates, with the subtype from the record's component type.
public struct CloudKitRecordFieldsSortKeySource: MediaSortKeySource {

    public init() {}

    public func sortKeys(for request: MediaSortKeyRequest) async -> MediaSortKeys? {
        guard let record = request.record else { return nil }
        return Self.sortKeys(forRecord: record)
    }

    /// The keys a record's plaintext fields give, for a builder that has the
    /// record in hand and does not read a file.
    public static func sortKeys(forRecord record: CloudKitMediaRecordDescriptor) -> MediaSortKeys {
        MediaSortKeys(recordCreatedAt: record.createdAt, componentType: record.mediaType)
    }
}

/// Reads the local file's creation date, which stands in for both dates, with
/// the subtype from the component type. Answers nil without a file or when the
/// file has no readable creation date.
public struct FileAttributesSortKeySource: MediaSortKeySource {

    public init() {}

    public func sortKeys(for request: MediaSortKeyRequest) async -> MediaSortKeys? {
        guard let fileURL = request.fileURL else { return nil }
        let keys = Self.sortKeys(forFileAt: fileURL, componentType: request.componentType)
        return keys.dateAdded == nil ? nil : keys
    }

    /// The keys a file's attributes give, with nil dates when its creation date
    /// cannot be read.
    public static func sortKeys(forFileAt fileURL: URL, componentType: MediaType) -> MediaSortKeys {
        let creationDate = try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate
        return MediaSortKeys(fileCreationDate: creationDate, componentType: componentType)
    }
}
