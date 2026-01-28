//
//  AlbumsSyncedStore.swift
//  EncameraCore
//
//  Created for iCloud synced data store feature.
//

import Foundation
import Combine

// MARK: - Synced Album Record

/// Represents an album record in the synced store
public struct SyncedAlbumRecord: Codable, Equatable {
    /// The name of the album (encrypted in storage)
    public let albumName: String
    
    /// When the album was added to the synced store
    public let dateAdded: Date
    
    /// Whether the album is hidden from the main album list
    public let isHidden: Bool
    
    public init(albumName: String, dateAdded: Date, isHidden: Bool) {
        self.albumName = albumName
        self.dateAdded = dateAdded
        self.isHidden = isHidden
    }
    
    /// Creates a SyncedAlbumRecord from a dictionary representation
    public static func from(dictionary: [String: Any]) -> SyncedAlbumRecord? {
        guard let albumName = dictionary["album_name"] as? String else {
            return nil
        }
        
        let dateAdded: Date
        if let date = dictionary["date_added"] as? Date {
            dateAdded = date
        } else if let timeInterval = dictionary["date_added"] as? TimeInterval {
            dateAdded = Date(timeIntervalSince1970: timeInterval)
        } else if let timeInterval = dictionary["date_added"] as? Double {
            dateAdded = Date(timeIntervalSince1970: timeInterval)
        } else {
            dateAdded = Date()
        }
        
        let isHidden = dictionary["is_hidden"] as? Bool ?? false
        
        return SyncedAlbumRecord(
            albumName: albumName,
            dateAdded: dateAdded,
            isHidden: isHidden
        )
    }
    
    /// Converts the record to a dictionary representation
    public func toDictionary() -> [String: Any] {
        return [
            "album_name": albumName,
            "date_added": dateAdded,
            "is_hidden": isHidden
        ]
    }
}

// MARK: - Album Sort Order

/// Sort orders for album queries
public enum AlbumSortOrder {
    case dateAddedAscending
    case dateAddedDescending
    case nameAscending
    case nameDescending
}

// MARK: - Albums Synced Store

/// Type-safe store for album metadata with iCloud sync
/// Provides album-specific CRUD operations and query methods
public class AlbumsSyncedStore: ObservableObject {
    
    // MARK: - Dependencies
    
    private let store: SyncedDataStore
    private let schema = SyncedStoreSchemas.albums
    
    // MARK: - Publishers
    
    /// Publisher that emits when albums data changes externally
    public var externalChangePublisher: AnyPublisher<Void, Never> {
        store.externalChangePublisher
            .filter { keys in keys.contains(SyncedStoreSchemas.albums.storageKey) }
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Initialization
    
    /// Creates a new AlbumsSyncedStore
    /// - Parameter store: The underlying SyncedDataStore instance
    public init(store: SyncedDataStore) {
        self.store = store
    }
    
    // MARK: - CRUD Operations
    
    /// Saves an album record to the synced store
    /// - Parameter album: The album record to save
    /// - Throws: SyncedStoreError if save fails
    public func save(_ album: SyncedAlbumRecord) throws {
        try store.save(album.toDictionary(), schema: schema)
    }
    
    /// Fetches an album record by name
    /// - Parameter name: The album name
    /// - Returns: The album record, or nil if not found
    /// - Throws: SyncedStoreError if fetch fails
    public func fetchAlbum(name: String) throws -> SyncedAlbumRecord? {
        guard let record = try store.fetch(primaryKey: name, schema: schema) else {
            return nil
        }
        return SyncedAlbumRecord.from(dictionary: record)
    }
    
    /// Deletes an album record by name
    /// - Parameter name: The album name
    public func deleteAlbum(name: String) {
        store.delete(primaryKey: name, schema: schema)
    }
    
    // MARK: - Query Operations
    
    /// Fetches all albums with optional sorting
    /// - Parameter sortedBy: The sort order (defaults to dateAddedAscending)
    /// - Returns: Array of album records
    /// - Throws: SyncedStoreError if fetch fails
    public func fetchAllAlbums(sortedBy: AlbumSortOrder = .dateAddedAscending) throws -> [SyncedAlbumRecord] {
        let sortDescriptor = sortDescriptor(for: sortedBy)
        let records = try store.fetchAll(schema: schema, sortDescriptors: [sortDescriptor])
        return records.compactMap { SyncedAlbumRecord.from(dictionary: $0) }
    }
    
    /// Fetches hidden albums with optional sorting
    /// - Parameter sortedBy: The sort order (defaults to dateAddedAscending)
    /// - Returns: Array of hidden album records
    /// - Throws: SyncedStoreError if fetch fails
    public func hiddenAlbums(sortedBy: AlbumSortOrder = .dateAddedAscending) throws -> [SyncedAlbumRecord] {
        let predicate = NSPredicate(format: "is_hidden == YES")
        let sortDescriptor = sortDescriptor(for: sortedBy)
        let records = try store.fetchAll(schema: schema, predicate: predicate, sortDescriptors: [sortDescriptor])
        return records.compactMap { SyncedAlbumRecord.from(dictionary: $0) }
    }
    
    /// Fetches visible (non-hidden) albums with optional sorting
    /// - Parameter sortedBy: The sort order (defaults to dateAddedAscending)
    /// - Returns: Array of visible album records
    /// - Throws: SyncedStoreError if fetch fails
    public func visibleAlbums(sortedBy: AlbumSortOrder = .dateAddedAscending) throws -> [SyncedAlbumRecord] {
        let predicate = NSPredicate(format: "is_hidden == NO OR is_hidden == nil")
        let sortDescriptor = sortDescriptor(for: sortedBy)
        let records = try store.fetchAll(schema: schema, predicate: predicate, sortDescriptors: [sortDescriptor])
        return records.compactMap { SyncedAlbumRecord.from(dictionary: $0) }
    }
    
    // MARK: - Convenience Methods
    
    /// Sets the hidden state for an album
    /// - Parameters:
    ///   - albumName: The album name
    ///   - isHidden: Whether the album should be hidden
    /// - Throws: SyncedStoreError if save fails
    public func setAlbumHidden(_ albumName: String, isHidden: Bool) throws {
        // Try to fetch existing record to preserve dateAdded
        if let existing = try fetchAlbum(name: albumName) {
            let updated = SyncedAlbumRecord(
                albumName: existing.albumName,
                dateAdded: existing.dateAdded,
                isHidden: isHidden
            )
            try save(updated)
        } else {
            // Create new record
            let newRecord = SyncedAlbumRecord(
                albumName: albumName,
                dateAdded: Date(),
                isHidden: isHidden
            )
            try save(newRecord)
        }
    }
    
    /// Checks if an album is hidden
    /// - Parameter albumName: The album name
    /// - Returns: True if the album is hidden, false otherwise
    /// - Throws: SyncedStoreError if fetch fails
    public func isAlbumHidden(_ albumName: String) throws -> Bool {
        guard let album = try fetchAlbum(name: albumName) else {
            return false
        }
        return album.isHidden
    }
    
    /// Ensures an album exists in the synced store with default values
    /// Does nothing if the album already exists
    /// - Parameters:
    ///   - albumName: The album name
    ///   - isHidden: Initial hidden state (defaults to false)
    /// - Throws: SyncedStoreError if save fails
    public func ensureAlbumExists(_ albumName: String, isHidden: Bool = false) throws {
        if try fetchAlbum(name: albumName) == nil {
            let newRecord = SyncedAlbumRecord(
                albumName: albumName,
                dateAdded: Date(),
                isHidden: isHidden
            )
            try save(newRecord)
        }
    }
    
    /// Gets the count of all albums
    /// - Returns: The total number of albums
    public func albumCount() throws -> Int {
        return try store.count(schema: schema)
    }
    
    /// Gets the count of hidden albums
    /// - Returns: The number of hidden albums
    public func hiddenAlbumCount() throws -> Int {
        let predicate = NSPredicate(format: "is_hidden == YES")
        return try store.count(schema: schema, predicate: predicate)
    }
    
    // MARK: - Private Helpers
    
    private func sortDescriptor(for order: AlbumSortOrder) -> NSSortDescriptor {
        switch order {
        case .dateAddedAscending:
            return NSSortDescriptor(key: "date_added", ascending: true)
        case .dateAddedDescending:
            return NSSortDescriptor(key: "date_added", ascending: false)
        case .nameAscending:
            return NSSortDescriptor(key: "album_name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        case .nameDescending:
            return NSSortDescriptor(key: "album_name", ascending: false, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        }
    }
    
    // MARK: - Utility
    
    /// Clears all album data from the synced store
    public func clearAll() {
        store.clearAll(schema: schema)
    }
}
