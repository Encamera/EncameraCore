//
//  CloudKitMigrationPlan.swift
//  EncameraCore
//
//  The durable checkpoint for a transfer between local storage and CloudKit: a
//  whole album or selected items, in either direction. A migration is a list of per-file work items, each in a state machine that is
//  persisted (encrypted, atomically) after EVERY transition. That on-disk plan —
//  not CloudKit's deprecated long-lived ops — is the source of truth that makes the
//  migration resumable across a crash, app kill, or power-off.
//  See plans/cloudkit-migration/12-local-to-cloudkit-migration.md.
//

import Foundation

// MARK: - Item state machine

/// The lifecycle of a single media component as it moves to CloudKit. The ordering
/// encodes the safety invariant: a local original is deleted ONLY after its record
/// is `verified` in CloudKit.
public enum MigrationItemState: String, Codable, Sendable {
    case pending          // not started
    case uploading        // CloudKit save in flight (operationID recorded)
    case uploaded         // record saved, not yet verified
    case verified         // confirmed present in CloudKit with matching size/changeTag
    case sourceDeleted    // local original removed -> item fully done
    /// A move back to this device asked CloudKit to delete the record, but the
    /// delete is still queued. The record may be live, so the album cannot finalize
    /// until a later run confirms it gone.
    case removalPending
    case failed           // retryable failure recorded in `lastError`
    case skipped          // nothing to migrate (source ciphertext missing) -> terminal

    /// Whether the item needs no further work. `skipped` is terminal too — an item whose
    /// source file is gone has nothing to migrate, so it must not block completion or be
    /// retried forever (which would wedge the whole album).
    public var isDone: Bool { self == .sourceDeleted || self == .skipped }
}

// MARK: - Queue inputs

/// What migrating an item from iCloud Drive costs, worked out once at plan time
/// from its media type and size so ordering never reads a file. Every iCloud
/// Drive file is ENC2: a video at or over `SeekableEncryptedFormat.threshold` is
/// re-encrypted into the seekable format before upload, and everything else
/// uploads its ciphertext as it is.
///
/// Downloading the encrypted file needs no key and may happen at any time, locked
/// or unlocked; disk space is left to the system, and an evicted file simply
/// counts as not processed yet. Re-encryption writes plaintext to a scratch
/// directory, so it runs only while the phone is unlocked, as a best effort: if
/// the phone locks partway through, the scratch output is wiped and the item
/// restarts at the next unlock. `BlobMigrationOrder` therefore never returns an
/// encrypting item while the phone is locked.
///
/// The kind is an ordering input only. The upload step makes its own re-encrypt
/// decision from the file it reads.
public enum MigrationItemKind: String, Codable, Sendable, Equatable {
    /// Uploads its existing ciphertext; needs no key and no plaintext.
    case ciphertextOnly
    /// Re-encrypted before upload; writes plaintext scratch, so unlocked only.
    case encrypting

    public init(mediaType: MediaType, sizeBytes: Int64) {
        self = mediaType == .video && sizeBytes >= Int64(SeekableEncryptedFormat.threshold)
            ? .encrypting : .ciphertextOnly
    }
}

/// Why the user asked for an item to migrate ahead of the rest. Each reason is one
/// tier of `BlobMigrationOrder`, ranked in declaration order: a new reason is a new
/// case and a new tier, not new queue code.
public enum MigrationPriorityReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// An operation is waiting on the item: a move to another album, an edit, or
    /// making it the cover. Leaves a deferred item deferred.
    case userAction
    /// The user opened the item in the viewer or player, and its bytes decrypted.
    /// The request also clears a deferral the decrypt disproves
    /// (`MigrationPlan.prioritizeViewed`); a record in another album stays deferred.
    case viewed

    /// Lower ranks run first.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

/// A user request recorded on a plan item by `prioritize`, persisted with the plan
/// so the order survives a relaunch.
public struct MigrationPriorityRequest: Codable, Sendable, Equatable {
    public let reason: MigrationPriorityReason
    public let requestedAt: Date

    public init(reason: MigrationPriorityReason, requestedAt: Date) {
        self.reason = reason
        self.requestedAt = requestedAt
    }
}

/// Why an item's move from its iCloud Drive file into CloudKit is deferred. A
/// deferred item is not done: it stays `pending`, keeps its reason across
/// re-plans, and is retried in the last tier of `BlobMigrationOrder`, which runs
/// only on Wi-Fi. Its file stays in the folder and its index component stays
/// `.iCloudDrive`, so it is still read from iCloud Drive meanwhile. The raw values
/// are stored in plan files.
public enum MigrationDeferralReason: String, Codable, Sendable, Equatable {
    /// The file's bytes do not parse as encrypted media, or the key its stamp
    /// names is held and does not open it.
    case unreadable
    /// The file stayed an iCloud Drive placeholder through the blob migration's
    /// bound of failed downloads made while the device had a network
    /// (`ICloudDriveBlobMigration.defaultMaxFailedDownloads` unless set).
    case neverDownloads
    /// Well-formed ciphertext that no key on this device opens.
    case missingKey
    /// A record with the item's name belongs to another CloudKit album.
    case recordInAnotherAlbum
}

// MARK: - Work item

/// One media component (a photo, or one half of a Live Photo) to migrate. The
/// `mediaID` + `mediaType` pair re-derives the on-disk ciphertext/preview URLs and
/// the CloudKit record name at execution time, so a moved directory or a changed
/// path layout never strands an item.
public struct MigrationItem: Codable, Sendable, Equatable {
    /// Stable grouping id (the `InteractableMedia` id). Identical across re-plans so
    /// a half-migrated file is never re-planned under a new id.
    public let mediaID: String
    /// The unique CloudKit record name `mediaID#mediaType.rawValue`
    /// (`CloudKitFileAccess.componentRecordName`). Persisted so a duplicate save is a
    /// no-op/conflict, never a second copy.
    public let recordName: String
    public let mediaType: MediaType
    /// Capture/encryption date captured from the local index entry at plan time, used
    /// for the record's `createdAt` so gallery ordering survives the move. The iCloud
    /// Drive blob migration sets it again from the album's index before the upload.
    public var createdAt: Date
    public var sizeBytes: Int64
    public var state: MigrationItemState
    /// Long-lived `CKOperation` id — a best-effort resume hint; correctness comes from
    /// the state machine + stable `recordName`, not this.
    public var operationID: String?
    public var lastError: String?
    /// The size of the copy the removal pass is about to act on, recorded when the
    /// item verified: the destination copy of a move back to this device, the local
    /// original of a move to CloudKit. The removal pass compares the file against it
    /// before deleting anything, without asking the server again.
    public var verifiedSizeBytes: Int64?
    /// The local original's modification date when a move to CloudKit verified it.
    /// An original rewritten since (a rotation, say) is not what CloudKit holds, so
    /// the removal pass keeps it.
    public var verifiedModificationDate: Date?
    /// Whether migrating the item re-encrypts it, set once from `mediaType` and the
    /// planned `sizeBytes`. A later size update leaves it as planned.
    public let kind: MigrationItemKind
    /// The user's request to migrate this item ahead of the rest, stamped only by
    /// `prioritize`. Nil for an item nobody asked for.
    public var priorityRequest: MigrationPriorityRequest?
    /// Why the item's move is deferred to the last tier. Nil for every other item.
    public var deferralReason: MigrationDeferralReason?
    /// How many downloads of the item's evicted iCloud Drive file failed in a row
    /// while the device was on Wi-Fi. Nil until one fails; cleared by a download
    /// that succeeds.
    public var failedDownloads: Int?

    public init(mediaID: String,
                recordName: String,
                mediaType: MediaType,
                createdAt: Date,
                sizeBytes: Int64,
                state: MigrationItemState = .pending,
                operationID: String? = nil,
                lastError: String? = nil,
                priorityRequest: MigrationPriorityRequest? = nil) {
        self.mediaID = mediaID
        self.recordName = recordName
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
        self.state = state
        self.operationID = operationID
        self.lastError = lastError
        self.kind = MigrationItemKind(mediaType: mediaType, sizeBytes: sizeBytes)
        self.priorityRequest = priorityRequest
    }

    /// Whether the item is deferred: not done, and retried last, on Wi-Fi.
    public var isDeferred: Bool { deferralReason != nil && !state.isDone }

    private enum CodingKeys: String, CodingKey {
        case mediaID, recordName, mediaType, createdAt, sizeBytes, state, operationID, lastError
        case verifiedSizeBytes, verifiedModificationDate, kind, priorityRequest, failedDownloads
        case deferralReason = "unmovableReason"
    }

    /// Reads an item. One written while a reason ended the item `skipped` reads
    /// as deferred: `pending` with its reason.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaID = try container.decode(String.self, forKey: .mediaID)
        recordName = try container.decode(String.self, forKey: .recordName)
        mediaType = try container.decode(MediaType.self, forKey: .mediaType)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        state = try container.decode(MigrationItemState.self, forKey: .state)
        operationID = try container.decodeIfPresent(String.self, forKey: .operationID)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        verifiedSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .verifiedSizeBytes)
        verifiedModificationDate = try container.decodeIfPresent(Date.self, forKey: .verifiedModificationDate)
        kind = try container.decode(MigrationItemKind.self, forKey: .kind)
        priorityRequest = try container.decodeIfPresent(MigrationPriorityRequest.self, forKey: .priorityRequest)
        deferralReason = try container.decodeIfPresent(MigrationDeferralReason.self, forKey: .deferralReason)
        failedDownloads = try container.decodeIfPresent(Int.self, forKey: .failedDownloads)
        if deferralReason != nil, state == .skipped { state = .pending }
    }

    /// Records a request for this item. A request never lowers the item's tier: a
    /// lower-ranked reason is ignored and a higher-ranked one replaces the stamp. A
    /// repeat `.userAction` keeps its first time, so user requests run in the order
    /// they were first made; a repeat `.viewed` takes the new time, so the most
    /// recent view counts.
    public mutating func recordPriorityRequest(_ reason: MigrationPriorityReason, at date: Date) {
        if let existing = priorityRequest {
            if existing.reason.rank < reason.rank { return }
            if existing.reason == reason, reason == .userAction { return }
        }
        priorityRequest = MigrationPriorityRequest(reason: reason, requestedAt: date)
    }

    /// The `createdAt` a media item's record gets: its capture date, else its
    /// encryption date, else the album's creation date.
    public static func createdAt(dateTaken: Date?, dateEncrypted: Date?, albumCreationDate: Date) -> Date {
        dateTaken ?? dateEncrypted ?? albumCreationDate
    }

    /// Records the download of the item's evicted file at `url`: its size once
    /// downloaded, the error otherwise. `result` is the materializer's result for
    /// `url`, nil when it reported none. Returns whether the file downloaded.
    @discardableResult
    mutating func recordMaterialization(_ result: Result<URL, Error>?, of url: URL) -> Bool {
        switch result {
        case .success:
            if let size = url.fileSizeBytes() { sizeBytes = size }
            lastError = nil
            return true
        case .failure(let error):
            lastError = "\(error)"
        case .none:
            lastError = "iCloud Drive did not report a result for this file"
        }
        return false
    }
}

// MARK: - Endpoints, scope, direction

/// One side of a transfer: an album named in the clear (the plan is encrypted at
/// rest), the storage plane it lives on, and for a CloudKit album its
/// `Album.albumID` — including the destination of a move to CloudKit, once the
/// engine has resolved which album that is.
public struct MigrationEndpoint: Codable, Sendable, Equatable {
    public let albumName: String
    public let storage: StorageType
    public let cloudKitAlbumID: String?
    /// Whether the move created this CloudKit album rather than adopting one that
    /// already existed, here or on another device. Only an album the move created
    /// may be deleted when the move is rolled back. Absent in a plan written before
    /// the field existed, which reads as adopted.
    public let createdByMove: Bool

    public init(albumName: String, storage: StorageType, cloudKitAlbumID: String? = nil,
                createdByMove: Bool = false) {
        self.albumName = albumName
        self.storage = storage
        self.cloudKitAlbumID = cloudKitAlbumID
        self.createdByMove = createdByMove
    }

    private enum CodingKeys: String, CodingKey {
        case albumName, storage, cloudKitAlbumID, createdByMove
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(albumName: try container.decode(String.self, forKey: .albumName),
                  storage: try container.decode(StorageType.self, forKey: .storage),
                  cloudKitAlbumID: try container.decodeIfPresent(String.self, forKey: .cloudKitAlbumID),
                  createdByMove: try container.decodeIfPresent(Bool.self, forKey: .createdByMove) ?? false)
    }

    public init(album: Album) {
        self.init(albumName: album.name, storage: album.storageOption, cloudKitAlbumID: album.albumID)
    }

    /// The `Album.id` this endpoint names, so plan paths and the engine's active-set
    /// claims key on the same string the rest of the app uses.
    public var albumID: String {
        if let cloudKitAlbumID {
            return "\(cloudKitAlbumID)_\(StorageType.cloudKit.rawValue)"
        }
        return "\(albumName)_\(storage.rawValue)"
    }

    /// The same endpoint under another album name. Storage and `cloudKitAlbumID` are
    /// kept, so a move to CloudKit still lands in the album it resolved.
    public func renamed(to albumName: String) -> MigrationEndpoint {
        MigrationEndpoint(albumName: albumName, storage: storage, cloudKitAlbumID: cloudKitAlbumID,
                          createdByMove: createdByMove)
    }

    /// The name to show for this endpoint. A CloudKit album is found by its id, since
    /// a rename on any device leaves the persisted `albumName` behind.
    public func displayName(among albums: [Album]) -> String {
        guard let cloudKitAlbumID else { return albumName }
        return albums.first { $0.albumID == cloudKitAlbumID }?.name ?? albumName
    }
}

public enum MigrationScope: String, Codable, Sendable {
    /// Every item in the album; finalize flips the album's storage.
    case album
    /// The selected items; finalize flips nothing.
    case items
}

public enum MigrationDirection: Sendable, Equatable {
    /// Source `.local` or `.icloud`, destination `.cloudKit`.
    case toCloudKit
    /// Source `.cloudKit`, destination `.local`.
    case toLocal
}

/// How the last run of a plan ended in failure, persisted so launch-time resume and
/// the upgrade offer can tell an automatic retry of a failed plan from a run the
/// user started. Written when a run ends `.failed`; cleared when the user starts one.
public struct MigrationLastFailure: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable {
        /// iCloud is full.
        case quota
        /// A key the run needed is not on this device.
        case missingKey
        /// No usable iCloud account.
        case accountUnavailable
        /// Anything else; retried automatically.
        case other
    }

    /// How long a quota failure holds off automatic resume. Space freed in iCloud
    /// is not observable, so the plan is retried once the window has passed.
    public static let quotaRetryInterval: TimeInterval = 24 * 60 * 60

    public let category: Category
    public let date: Date
    /// Fingerprints of the keys on this device when a `.missingKey` failure was recorded, so a key
    /// added since re-enables automatic resume. Empty for other categories.
    public let heldKeyFingerprints: [String]

    public init(category: Category, date: Date, heldKeyFingerprints: [String] = []) {
        self.category = category
        self.date = date
        self.heldKeyFingerprints = heldKeyFingerprints
    }

    /// Whether launch-time resume should leave the plan alone. A quota failure waits
    /// out `quotaRetryInterval`, a lost account waits for one to be available, and a
    /// missing key waits for a key that was not held at the failure. Every other
    /// failure is retried.
    public func blocksAutomaticResume(now: Date,
                                      isAccountAvailable: Bool,
                                      heldKeyFingerprints current: [String]) -> Bool {
        switch category {
        case .quota:
            return now.timeIntervalSince(date) < Self.quotaRetryInterval
        case .accountUnavailable:
            return !isAccountAvailable
        case .missingKey:
            return Set(current).isSubset(of: Set(heldKeyFingerprints))
        case .other:
            return false
        }
    }
}

public enum MigrationPlanError: Error, Equatable {
    /// Only local/iCloud Drive -> CloudKit and CloudKit -> local are transfers.
    case unsupportedStoragePair(source: StorageType, destination: StorageType)
    /// An album-scope plan moves one album between planes, so both ends share a
    /// name and the plan id is `MigrationPlan.albumPlanID`.
    case invalidAlbumScope
    case unsupportedVersion(Int)
}

// MARK: - Plan

/// One transfer between local storage and CloudKit: a whole album or a selection of
/// its items, in either direction, as work items plus enough context to be
/// self-describing on disk. Persisted encrypted with the source album's key under
/// `~/Library/Application Support/CloudKitMigration/<sha256(source album.id)>/<id>.encplan`.
///
/// Item states read the same in both directions: `uploading` is the transfer in
/// flight, `uploaded` the bytes at the destination, `verified` the destination copy
/// confirmed, and `sourceDeleted` the source copy removed.
public struct MigrationPlan: Codable, Sendable {
    public static let currentVersion = 1
    /// The id of every album-scope plan. One album-scope plan per source album.
    public static let albumPlanID = "album"

    /// `albumPlanID` for album scope, a UUID for item scope.
    public let id: String
    public let source: MigrationEndpoint
    public let destination: MigrationEndpoint
    public let scope: MigrationScope
    public var items: [MigrationItem]
    public let createdAt: Date
    public let version: Int
    /// Set when the user explicitly cancels. A cancelled plan is kept on disk (so a
    /// partially-moved album can still be finished by a manual resume, recovering any
    /// already-uploaded item), but launch-time auto-resume skips it — so a cancel is
    /// durable and is never silently restarted in the background. Cleared on re-plan.
    public var cancelledAt: Date?
    /// How the last run ended, when it failed. Kept across a re-plan so an automatic
    /// resume still knows the plan failed; cleared when the user starts a run.
    public var lastFailure: MigrationLastFailure?

    /// Total over the storage pair, which the initializer restricts to the two
    /// supported transfers.
    public var direction: MigrationDirection {
        source.storage == .cloudKit ? .toLocal : .toCloudKit
    }

    public init(id: String,
                source: MigrationEndpoint,
                destination: MigrationEndpoint,
                scope: MigrationScope,
                items: [MigrationItem],
                createdAt: Date,
                version: Int = MigrationPlan.currentVersion,
                cancelledAt: Date? = nil,
                lastFailure: MigrationLastFailure? = nil) throws {
        try Self.validate(id: id, source: source, destination: destination, scope: scope)
        self.id = id
        self.source = source
        self.destination = destination
        self.scope = scope
        self.items = items
        self.createdAt = createdAt
        self.version = version
        self.cancelledAt = cancelledAt
        self.lastFailure = lastFailure
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, destination, scope, items, createdAt, version, cancelledAt, lastFailure
    }

    /// Rejects any other version and any plan the initializer would reject, so a
    /// stale or foreign checkpoint reads as absent rather than driving the engine.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw MigrationPlanError.unsupportedVersion(version) }
        try self.init(id: try container.decode(String.self, forKey: .id),
                      source: try container.decode(MigrationEndpoint.self, forKey: .source),
                      destination: try container.decode(MigrationEndpoint.self, forKey: .destination),
                      scope: try container.decode(MigrationScope.self, forKey: .scope),
                      items: try container.decode([MigrationItem].self, forKey: .items),
                      createdAt: try container.decode(Date.self, forKey: .createdAt),
                      version: Self.currentVersion,
                      cancelledAt: try container.decodeIfPresent(Date.self, forKey: .cancelledAt),
                      lastFailure: try container.decodeIfPresent(MigrationLastFailure.self, forKey: .lastFailure))
    }

    private static func validate(id: String,
                                 source: MigrationEndpoint,
                                 destination: MigrationEndpoint,
                                 scope: MigrationScope) throws {
        switch (source.storage, destination.storage) {
        case (.local, .cloudKit), (.icloud, .cloudKit), (.cloudKit, .local):
            break
        default:
            throw MigrationPlanError.unsupportedStoragePair(source: source.storage,
                                                             destination: destination.storage)
        }
        if scope == .album, source.albumName != destination.albumName || id != albumPlanID {
            throw MigrationPlanError.invalidAlbumScope
        }
    }

    /// This plan after a local album named by `oldAlbumID` is renamed to `newName`:
    /// every endpoint naming that album takes the new name, and nothing else changes.
    /// Nil when neither endpoint names it. An album-scope plan is one album on two
    /// planes, so it follows its source and renames both ends together.
    public func renamingAlbum(_ oldAlbumID: String, to newName: String) throws -> MigrationPlan? {
        let renamesSource = source.albumID == oldAlbumID
        let renamesDestination = scope == .album ? renamesSource : destination.albumID == oldAlbumID
        guard renamesSource || renamesDestination else { return nil }
        return try MigrationPlan(id: id,
                                 source: renamesSource ? source.renamed(to: newName) : source,
                                 destination: renamesDestination ? destination.renamed(to: newName) : destination,
                                 scope: scope,
                                 items: items,
                                 createdAt: createdAt,
                                 version: version,
                                 cancelledAt: cancelledAt,
                                 lastFailure: lastFailure)
    }

    // MARK: Factories

    /// The album-scope plan that moves `album` to the other plane: a local or iCloud
    /// Drive album to CloudKit, a CloudKit album to local storage.
    ///
    /// `cloudKitAlbumID` is the id of the CloudKit album a move to CloudKit lands in.
    /// It is persisted in the destination endpoint so a resume reuses it; nil until
    /// the engine has resolved it, and always nil for a move to local storage.
    /// `cloudKitAlbumCreatedByMove` says whether the engine created that album.
    public static func album(_ album: Album,
                             items: [MigrationItem],
                             createdAt: Date = Date(),
                             cloudKitAlbumID: String? = nil,
                             cloudKitAlbumCreatedByMove: Bool = false) throws -> MigrationPlan {
        let destination: StorageType = album.storageOption == .cloudKit ? .local : .cloudKit
        return try MigrationPlan(id: albumPlanID,
                                 source: MigrationEndpoint(album: album),
                                 destination: MigrationEndpoint(albumName: album.name,
                                                                storage: destination,
                                                                cloudKitAlbumID: destination == .cloudKit ? cloudKitAlbumID : nil,
                                                                createdByMove: destination == .cloudKit && cloudKitAlbumCreatedByMove),
                                 scope: .album,
                                 items: items,
                                 createdAt: createdAt)
    }

    /// An item-scope plan moving `items` from `source` into `destination`.
    public static func items(source: Album,
                             destination: Album,
                             items: [MigrationItem],
                             id: String = UUID().uuidString) throws -> MigrationPlan {
        try MigrationPlan(id: id,
                          source: MigrationEndpoint(album: source),
                          destination: MigrationEndpoint(album: destination),
                          scope: .items,
                          items: items,
                          createdAt: Date())
    }

    /// An item-scope plan for the selected media. Each component is its own item,
    /// so a Live Photo contributes two, sized from the source's on-disk ciphertext.
    public static func items(source: Album,
                             destination: Album,
                             media: [InteractableMedia<EncryptedMedia>],
                             id: String = UUID().uuidString) throws -> MigrationPlan {
        let sourceModel = source.storageOption.modelForType.init(album: source)
        let items = media.flatMap { interactable in
            interactable.underlyingMedia.map { component in
                let fileURL = sourceModel.driveURLForMedia(withID: component.id, type: component.mediaType)
                return MigrationItem(
                    mediaID: component.id,
                    recordName: MediaRecordName.componentRecordName(mediaID: component.id, type: component.mediaType),
                    mediaType: component.mediaType,
                    createdAt: interactable.timestamp ?? Date(),
                    sizeBytes: fileURL.fileSizeBytes() ?? 0
                )
            }
        }
        return try Self.items(source: source, destination: destination, items: items, id: id)
    }

    // MARK: Priority

    /// Stamps every item of the given media with `reason` at `date`, both halves of
    /// a Live Photo together (see `MigrationItem.recordPriorityRequest`). The only
    /// way a plan's order changes; `MigrationPlanStore.prioritize` checkpoints it.
    public mutating func prioritize(mediaIDs: Set<String>, reason: MigrationPriorityReason, at date: Date) {
        for index in items.indices where mediaIDs.contains(items[index].mediaID) {
            items[index].recordPriorityRequest(reason, at: date)
        }
    }

    /// Stamps every item of the given media with `.viewed` at `date`, as
    /// `prioritize`, for an open in the viewer or player that decrypted them, and
    /// clears every deferral the decrypt disproves: the bytes were downloaded,
    /// readable and opened by a key this device holds. A record in another album
    /// stays deferred, since decrypting does not change who owns it. A cleared
    /// item rejoins the ordinary tiers under its `.viewed` stamp.
    /// `MigrationPlanStore.prioritizeViewed` checkpoints it.
    public mutating func prioritizeViewed(mediaIDs: Set<String>, at date: Date) {
        prioritize(mediaIDs: mediaIDs, reason: .viewed, at: date)
        for index in items.indices where mediaIDs.contains(items[index].mediaID) {
            if items[index].deferralReason != .recordInAnotherAlbum { items[index].deferralReason = nil }
        }
    }

    /// Applies a request `MigrationPlanStore.prioritize` recorded: a `.viewed`
    /// request is an open that decrypted the media (`prioritizeViewed`), any other
    /// only stamps its reason.
    mutating func applyPriorityRequest(mediaIDs: Set<String>, reason: MigrationPriorityReason, at date: Date) {
        if reason == .viewed {
            prioritizeViewed(mediaIDs: mediaIDs, at: date)
        } else {
            prioritize(mediaIDs: mediaIDs, reason: reason, at: date)
        }
    }

    // MARK: Removal

    /// Drops every item of the given media, both halves of a Live Photo together,
    /// so nothing migrates them. `MigrationPlanStore.remove(mediaIDs:)` checkpoints it.
    public mutating func remove(mediaIDs: Set<String>) {
        items.removeAll { mediaIDs.contains($0.mediaID) }
    }

// MARK: Progress

    /// Total bytes across every item — the denominator for byte-weighted progress.
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    /// Bytes whose record is at least `verified` (i.e. durably in CloudKit). Used for
    /// an honest, monotonic progress fraction rather than raw item count.
    public var migratedBytes: Int64 {
        items.reduce(0) { acc, item in
            switch item.state {
            case .verified, .removalPending, .sourceDeleted: return acc + item.sizeBytes
            default: return acc
            }
        }
    }

    /// The share of an item's progress that removing its source copy accounts for.
    /// A whole album moving back to this device removes nothing until every item has
    /// downloaded, so without this share the ring sits full for the whole removal
    /// pass while the move is still running.
    public static let sourceRemovalShare = 0.2

    /// Fraction in `0...1` (1 when there is no work). Each item is weighted by its
    /// size, and is complete once its source copy is removed (or it is skipped); a
    /// `verified` item has done all but `sourceRemovalShare` of its work.
    ///
    /// An item whose size is unknown (`0`, e.g. a CloudKit record the size sidecar
    /// has not seen) is weighted as the average known item, so it still moves the
    /// ring. With no sizes at all every item weighs the same.
    public var fractionComplete: Double { fractionComplete(inFlight: [:]) }

    /// `fractionComplete` with partial credit for items part-way through their
    /// transfer: `inFlight` maps an item index to how far its transfer has got,
    /// 0...1, where 1 is the credit `verified` earns. Only an item still pending or
    /// transferring takes it, so a report that arrives after the item moved on
    /// never counts twice.
    public func fractionComplete(inFlight: [Int: Double]) -> Double {
        guard !items.isEmpty else { return 1 }
        let known = items.lazy.map(\.sizeBytes).filter { $0 > 0 }
        let knownCount = known.count
        let fallbackWeight = knownCount > 0 ? Double(known.reduce(0, +)) / Double(knownCount) : 1
        var done = 0.0
        var total = 0.0
        for (index, item) in items.enumerated() {
            let weight = item.sizeBytes > 0 ? Double(item.sizeBytes) : fallbackWeight
            total += weight
            switch item.state {
            case .sourceDeleted, .skipped: done += weight
            case .verified, .removalPending: done += weight * (1 - Self.sourceRemovalShare)
            case .pending, .uploading, .uploaded:
                let transferred = min(max(inFlight[index] ?? 0, 0), 1)
                done += weight * (1 - Self.sourceRemovalShare) * transferred
            case .failed: break
            }
        }
        return total > 0 ? min(done / total, 1) : 1
    }

    /// The share of an item's transfer that downloading its iCloud Drive original
    /// accounts for, before the upload. Nothing downloads for any other source.
    public var downloadShare: Double {
        direction == .toCloudKit && source.storage == .icloud ? 0.5 : 0
    }

    public var verifiedCount: Int {
        items.filter { $0.state == .verified || $0.state == .removalPending || $0.state == .sourceDeleted }.count
    }
    /// Items whose record delete is queued but not confirmed.
    public var removalPendingCount: Int { items.filter { $0.state == .removalPending }.count }
    public var failedCount: Int { items.filter { $0.state == .failed }.count }
    /// Items whose source copy is gone.
    public var sourceDeletedCount: Int { items.filter { $0.state == .sourceDeleted }.count }
    public var skippedCount: Int { items.filter { $0.state == .skipped }.count }
    /// Deferred items, still on iCloud Drive: "N items can't be moved right now".
    public var deferredCount: Int { items.filter(\.isDeferred).count }
    /// The record names of the deferred items.
    public var deferredRecordNames: Set<String> { Set(items.filter(\.isDeferred).map(\.recordName)) }

    /// Whether every item is fully done (`sourceDeleted`).
    public var isComplete: Bool { !items.isEmpty && items.allSatisfy { $0.state.isDone } }

    /// Whether any item still needs work (drives launch-time resume detection).
    public var hasRemainingWork: Bool { items.contains { !$0.state.isDone } }
}

// MARK: - Persistence

/// Reads/writes one `Codable` plan, encrypted with a symmetric key and written
/// atomically (temp-file + rename via `Data.WritingOptions.atomic`) so a crash
/// mid-write can never corrupt the checkpoint.
public actor EncryptedPlanStore<Plan: Codable & Sendable>: DebugPrintable {

    private let keyBytes: [UInt8]
    private let planURL: URL

    /// Direct initializer — the only stored-property init on the generic type.
    /// Convenience inits that derive `keyBytes`/`planURL` from domain objects
    /// live on concrete typealiases (e.g. `MigrationPlanStore.init(album:)`).
    init(keyBytes: [UInt8], planURL: URL) {
        self.keyBytes = keyBytes
        self.planURL = planURL
    }

    /// Loads and decrypts the plan, or `nil` if absent/unreadable/corrupt. A file
    /// that decrypts but does not decode (another plan version, or a plan the type
    /// rejects) is deleted: nothing can ever resume it. One that does not decrypt
    /// is kept, since it may belong to an album whose key this store was not given.
    public func load() -> Plan? {
        guard let fileData = try? Data(contentsOf: planURL) else {
            printDebug("load MISS file=\(planURL.lastPathComponent) — no plan file on disk")
            return nil
        }
        guard let plaintext = try? MediaIndexStore.decrypt(fileData, keyBytes: keyBytes) else {
            printDebug("load FAILED file=\(planURL.lastPathComponent) bytes=\(fileData.count) — could not decrypt (wrong key or corrupt)")
            return nil
        }
        let plan: Plan
        do {
            plan = try JSONDecoder().decode(Plan.self, from: plaintext)
        } catch {
            printDebug("load DISCARD file=\(planURL.lastPathComponent) plaintext=\(plaintext.count)b — decrypted but did not decode as \(Plan.self): \(error)")
            try? MigrationPlanFileUtil.remove(planURL)
            return nil
        }
        printDebug("load ok file=\(planURL.lastPathComponent) plaintext=\(plaintext.count)b")
        return plan
    }

    /// Encrypts and atomically persists the plan. Called after every state transition.
    public func save(_ plan: Plan) throws {
        let encryptedBytes = try Self.write(plan, to: planURL, keyBytes: keyBytes)
        printDebug("save ok file=\(planURL.lastPathComponent) encrypted=\(encryptedBytes)b")
    }

    /// Encrypts `plan` with `keyBytes` and writes it atomically to `url`, excluded
    /// from backup. Returns the size written.
    @discardableResult
    static func write(_ plan: Plan, to url: URL, keyBytes: [UInt8]) throws -> Int {
        if Plan.self == MigrationPlan.self, MigrationPlanRemovals.shared.isRemovedPlan(at: url) {
            printDebug("save skip file=\(url.lastPathComponent) — the plan's album was deleted")
            return 0
        }
        var plan = plan
        if var migrationPlan = plan as? MigrationPlan {
            let removed = MigrationPlanRemovals.shared.mediaIDs(removedFromPlanAt: url)
            if !removed.isEmpty, migrationPlan.items.contains(where: { removed.contains($0.mediaID) }) {
                migrationPlan.remove(mediaIDs: removed)
            }
            for request in MigrationPlanPriorityRequests.shared.requests(madeOnPlanAt: url) {
                migrationPlan.applyPriorityRequest(mediaIDs: request.mediaIDs, reason: request.reason, at: request.date)
            }
            plan = migrationPlan as? Plan ?? plan
        }
        let plaintext = try JSONEncoder().encode(plan)
        let encrypted = try MediaIndexStore.encrypt(plaintext, keyBytes: keyBytes)
        try MigrationPlanFileUtil.createDirectory(holding: url)
        try encrypted.write(to: url, options: .atomic)
        MigrationPlanFileUtil.excludeFromBackup(url)
        if let plan = plan as? MigrationPlan {
            MigrationPlanStore.recordDestination(of: plan, planURL: url)
            MigrationPlanStore.recordRemainingWork(of: plan, planURL: url)
        }
        return encrypted.count
    }

    /// The plan at `url`, or nil when it is absent, does not decrypt with `keyBytes`,
    /// or does not decode. Unlike `load()`, never deletes the file.
    static func read(at url: URL, keyBytes: [UInt8]) -> Plan? {
        guard let fileData = try? Data(contentsOf: url),
              let plaintext = try? MediaIndexStore.decrypt(fileData, keyBytes: keyBytes) else { return nil }
        return try? JSONDecoder().decode(Plan.self, from: plaintext)
    }

    /// Removes the plan file (after the operation completes or is fully reverted).
    public func delete() {
        do {
            try MigrationPlanFileUtil.remove(planURL)
            if Plan.self == MigrationPlan.self {
                MigrationPlanStore.removeDestinationMarker(besidePlanAt: planURL)
                try? FileManager.default.removeItem(at: MigrationPlanStore.noRemainingWorkMarkerURL(besidePlanAt: planURL))
            }
            printDebug("delete ok file=\(planURL.lastPathComponent)")
        } catch {
            printDebug("delete FAILED file=\(planURL.lastPathComponent) error=\(error)")
        }
    }

    /// Whether a plan file currently exists on disk.
    public func exists() -> Bool {
        MigrationPlanFileUtil.exists(planURL)
    }
}

// MARK: - MigrationPlanStore

public typealias MigrationPlanStore = EncryptedPlanStore<MigrationPlan>

extension EncryptedPlanStore where Plan == MigrationPlan {

    /// The store for one plan, encrypted with its source album's key.
    public init(sourceAlbum: Album, planID: String) {
        self.init(keyBytes: sourceAlbum.key.keyBytes,
                  planURL: Self.planURL(sourceAlbum: sourceAlbum, planID: planID))
    }

    /// The store for `album`'s album-scope plan, whichever direction it runs.
    public init(album: Album) {
        self.init(sourceAlbum: album, planID: MigrationPlan.albumPlanID)
    }

    // MARK: Priority

    /// Records a user request for `items` and checkpoints the plan: stamps every
    /// plan item sharing a `mediaID` with one of them (so a Live Photo's halves go
    /// together) with `reason` and `date`, a `.viewed` request clearing the
    /// deferrals its decrypt disproves (`MigrationPlan.applyPriorityRequest`).
    /// Returns the saved plan, or nil when there is no plan. Nothing else reorders
    /// a plan's items.
    ///
    /// Every later save of this plan file in this process stamps the request again,
    /// whoever makes it, so a writer holding a copy it loaded before the request (a
    /// blob migration pass part-way through another item, an album step merging
    /// the folder into the plan it read) cannot drop it.
    @discardableResult
    public func prioritize(_ items: [MigrationItem],
                           reason: MigrationPriorityReason,
                           at date: Date = Date()) throws -> MigrationPlan? {
        let mediaIDs = Set(items.map(\.mediaID))
        guard var plan = load() else { return nil }
        MigrationPlanPriorityRequests.shared.record(mediaIDs, reason: reason, at: date, onPlanAt: planURL)
        plan.applyPriorityRequest(mediaIDs: mediaIDs, reason: reason, at: date)
        try save(plan)
        return plan
    }

    /// Records an open in the viewer or player that decrypted `items`: a `.viewed`
    /// `prioritize`, which also clears the deferrals the decrypt disproves.
    ///
    /// Every later save of this plan file in this process clears them again, so a
    /// writer holding a copy loaded before the open cannot defer the items again.
    /// A retry that defers one of them later in the process is cleared by its own
    /// save too, and the item stays in the ordinary tiers until the next launch.
    @discardableResult
    public func prioritizeViewed(_ items: [MigrationItem], at date: Date = Date()) throws -> MigrationPlan? {
        try prioritize(items, reason: .viewed, at: date)
    }

    // MARK: Removal

    /// Drops every plan item of the given media and checkpoints the plan, for media
    /// the user deleted. Returns the saved plan, or nil when there is no plan.
    ///
    /// Every later save of this plan file in this process drops them too, whoever
    /// makes it, so a writer holding a copy it loaded before the removal (a blob
    /// migration pass part-way through an item, an album step merging the folder
    /// into the plan it read) cannot write them back.
    @discardableResult
    public func remove(mediaIDs: Set<String>) throws -> MigrationPlan? {
        MigrationPlanRemovals.shared.record(mediaIDs, removedFromPlanAt: planURL)
        guard var plan = load() else { return nil }
        plan.remove(mediaIDs: mediaIDs)
        try save(plan)
        return plan
    }

    // MARK: Last failure

    /// Stamps the checkpoint with how its run failed. No-op when there is no plan.
    public func recordLastFailure(_ failure: MigrationLastFailure) async {
        guard var plan = load() else { return }
        plan.lastFailure = failure
        try? save(plan)
    }

    /// Clears the checkpoint's failure, for a run the user started.
    public func clearLastFailure() async {
        guard var plan = load(), plan.lastFailure != nil else { return }
        plan.lastFailure = nil
        try? save(plan)
    }

    // MARK: File location

    /// `~/Library/Application Support/CloudKitMigration/`.
    static func directoryURL() -> URL {
        MigrationPlanFileUtil.rootDirectory
    }

    /// `CloudKitMigration/<sha256(album.id)>/`. `album.id` includes the storage, so
    /// an album's forward and reverse plans never share a directory.
    static func directoryURL(forSource album: Album) -> URL {
        MigrationPlanFileUtil.sourceDirectory(albumID: album.id)
    }

    static func planURL(sourceAlbum: Album, planID: String) -> URL {
        MigrationPlanFileUtil.planURL(in: directoryURL(forSource: sourceAlbum), planID: planID)
    }

    /// The album-scope plan's location for `album`.
    static func planURL(for album: Album) -> URL {
        planURL(sourceAlbum: album, planID: MigrationPlan.albumPlanID)
    }

    // MARK: iCloud Drive album migration

    /// The store for the plan of an iCloud Drive album migration into the CloudKit
    /// album `cloudKitAlbumID`, encrypted with `album`'s key: the album-scope plan
    /// moving the iCloud Drive album `album` into that CloudKit album item by item.
    ///
    /// Kept apart from the whole-album move's plans and keyed by the CloudKit album
    /// id, which a rename of either album does not change. `plans(for:)`,
    /// `hasPlans(for:)` and `planRole(forAlbumID:)` do not see it, so the launch
    /// resume never runs it as a whole-album move.
    public init(iCloudDriveMigrationFrom album: Album, cloudKitAlbumID: String) {
        self.init(keyBytes: album.key.keyBytes,
                  planURL: Self.iCloudDriveMigrationPlanURL(cloudKitAlbumID: cloudKitAlbumID))
    }

    /// `CloudKitMigration/ICloudDriveAlbums/`, which holds one directory per
    /// CloudKit album an iCloud Drive album migrates into.
    static func iCloudDriveMigrationDirectoryURL() -> URL {
        MigrationPlanFileUtil.iCloudDriveAlbumsDirectory
    }

    /// `CloudKitMigration/ICloudDriveAlbums/<sha256("<albumID>_cloudKit")>/album.encplan`.
    static func iCloudDriveMigrationPlanURL(cloudKitAlbumID: String) -> URL {
        MigrationPlanFileUtil.albumPlanURL(in: MigrationPlanFileUtil.iCloudDriveAlbumDirectory(cloudKitAlbumID: cloudKitAlbumID))
    }

    /// The empty file beside an iCloud Drive album migration plan that has no item
    /// left to work on (`hasRemainingWork` false), so whether the plan still has
    /// work is known without its key. Written and removed with every save.
    static func noRemainingWorkMarkerURL(besidePlanAt planURL: URL) -> URL {
        planURL.deletingLastPathComponent().appendingPathComponent("no-remaining-work")
    }

    /// Writes or removes the no-remaining-work marker beside `plan` saved at
    /// `planURL`, for an iCloud Drive album migration plan only.
    static func recordRemainingWork(of plan: MigrationPlan, planURL: URL) {
        let albumsDirectory = planURL.deletingLastPathComponent().deletingLastPathComponent()
        guard albumsDirectory.standardizedFileURL.path == iCloudDriveMigrationDirectoryURL().standardizedFileURL.path else { return }
        let marker = noRemainingWorkMarkerURL(besidePlanAt: planURL)
        if plan.hasRemainingWork {
            try? FileManager.default.removeItem(at: marker)
        } else if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
    }

    /// Whether the iCloud Drive album migration plan at `planURL` has an item left
    /// to work on. Decrypts nothing.
    static func iCloudDriveMigrationPlanHasRemainingWork(at planURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: planURL.path)
            && !FileManager.default.fileExists(atPath: noRemainingWorkMarkerURL(besidePlanAt: planURL).path)
    }

    /// Whether an iCloud Drive album migration plan names the CloudKit album
    /// `cloudKitAlbumID`. Decrypts nothing.
    public static func hasICloudDriveMigrationPlan(cloudKitAlbumID: String) -> Bool {
        MigrationPlanFileUtil.exists(iCloudDriveMigrationPlanURL(cloudKitAlbumID: cloudKitAlbumID))
    }

    /// Removes the iCloud Drive album migration plan naming the CloudKit album
    /// `cloudKitAlbumID`, with its directory. Needs no key.
    public static func removeICloudDriveMigrationPlan(cloudKitAlbumID: String) {
        MigrationPlanFileUtil.removeIfPresent(MigrationPlanFileUtil.iCloudDriveAlbumDirectory(cloudKitAlbumID: cloudKitAlbumID))
    }

    /// The plan directory name for the album whose `Album.id` is `albumID`.
    static func sourceHash(albumID: String) -> String {
        MigrationPlanFileUtil.directoryName(albumID: albumID)
    }

    /// Every readable plan whose source is `album`, both scopes.
    public static func plans(for album: Album) async -> [MigrationPlan] {
        var plans: [MigrationPlan] = []
        for file in MigrationPlanFileUtil.planFiles(in: directoryURL(forSource: album)) {
            if let plan = await MigrationPlanStore(keyBytes: album.key.keyBytes, planURL: file).load() {
                plans.append(plan)
            }
        }
        return plans
    }

    /// Whether any plan file exists for `album` as the source — a cheap, synchronous
    /// check that decrypts nothing, for callers that only need to know whether to
    /// look further.
    public static func hasPlans(for album: Album) -> Bool {
        !MigrationPlanFileUtil.planFiles(in: directoryURL(forSource: album)).isEmpty
    }

    // MARK: Rename

    /// Carries every plan that names `oldAlbum` across its rename to `newAlbum`, for an
    /// album whose id is its name (local or iCloud Drive). The album's own plans move
    /// to the new id's directory with their endpoints renamed; plans of `otherAlbums`
    /// that move items into the album get their destination renamed in place. A
    /// rename keeps the album's key, so each plan is re-encrypted with the key it was
    /// written with. A plan that does not read is left where it is.
    ///
    /// Synchronous, because a rename is. Returns the album's own plans as carried.
    @discardableResult
    static func carryPlans(acrossRenameOf oldAlbum: Album, to newAlbum: Album,
                           otherAlbums: [Album]) throws -> [MigrationPlan] {
        var carried: [MigrationPlan] = []
        let oldDirectory = directoryURL(forSource: oldAlbum)
        let newDirectory = directoryURL(forSource: newAlbum)
        for file in MigrationPlanFileUtil.planFiles(in: oldDirectory) {
            guard let plan = read(at: file, keyBytes: oldAlbum.key.keyBytes),
                  let renamed = try plan.renamingAlbum(oldAlbum.id, to: newAlbum.name) else { continue }
            try write(renamed, to: MigrationPlanFileUtil.planURL(file, movedTo: newDirectory),
                      keyBytes: newAlbum.key.keyBytes)
            try MigrationPlanFileUtil.remove(file)
            removeDestinationMarker(besidePlanAt: file)
            carried.append(renamed)
        }
        MigrationPlanFileUtil.removeIfEmpty(oldDirectory)

        for album in otherAlbums where album.id != oldAlbum.id && album.id != newAlbum.id {
            for file in MigrationPlanFileUtil.planFiles(in: directoryURL(forSource: album)) {
                guard let plan = read(at: file, keyBytes: album.key.keyBytes),
                      plan.destination.albumID == oldAlbum.id,
                      let renamed = try plan.renamingAlbum(oldAlbum.id, to: newAlbum.name) else { continue }
                try write(renamed, to: file, keyBytes: album.key.keyBytes)
            }
        }
        return carried
    }

    /// Deletes every on-disk migration checkpoint (the encrypted per-file
    /// migration ledgers). Used by the erase flows so user-generated migration
    /// state does not survive a wipe.
    public static func clearAllPlans() throws {
        let dir = directoryURL()
        if MigrationPlanFileUtil.exists(dir) {
            try MigrationPlanFileUtil.remove(dir)
        }
    }
}

// MARK: - Removed media

/// The media removed from each plan file in this process
/// (`MigrationPlanStore.remove(mediaIDs:)`), which every save of that file drops,
/// and the plan files of deleted albums, which no save writes again. Held in
/// memory only: a copy of a plan loaded before a removal lives no longer than the
/// process, and media and album ids are never reused.
final class MigrationPlanRemovals: @unchecked Sendable {

    static let shared = MigrationPlanRemovals()

    private let lock = NSLock()
    private var removed: [String: Set<String>] = [:]
    private var removedPlans: Set<String> = []

    func recordRemovedPlan(at planURL: URL) {
        lock.withLock { _ = removedPlans.insert(Self.key(planURL)) }
    }

    func isRemovedPlan(at planURL: URL) -> Bool {
        lock.withLock { removedPlans.contains(Self.key(planURL)) }
    }

    func record(_ mediaIDs: Set<String>, removedFromPlanAt planURL: URL) {
        guard !mediaIDs.isEmpty else { return }
        lock.withLock { removed[Self.key(planURL), default: []].formUnion(mediaIDs) }
    }

    func mediaIDs(removedFromPlanAt planURL: URL) -> Set<String> {
        lock.withLock { removed[Self.key(planURL)] ?? [] }
    }

    private static func key(_ planURL: URL) -> String {
        planURL.standardizedFileURL.path
    }
}

// MARK: - Priority requests

/// The requests `MigrationPlanStore.prioritize` and `prioritizeViewed` made on
/// each plan file in this process, which every save of that file applies again
/// (`MigrationPlan.applyPriorityRequest`), a `.viewed` request clearing the
/// deferrals its decrypt disproved again too.
/// Stamping is idempotent and never lowers an item's tier
/// (`MigrationItem.recordPriorityRequest`), so a save of a copy that already
/// carries a request, or a later one, keeps what it has. Held in memory only: a
/// copy of a plan loaded before a request lives no longer than the process, and
/// the request itself is in the file it saved.
final class MigrationPlanPriorityRequests: @unchecked Sendable {

    struct Request: Equatable {
        let mediaIDs: Set<String>
        let reason: MigrationPriorityReason
        let date: Date
    }

    static let shared = MigrationPlanPriorityRequests()

    private let lock = NSLock()
    private var requests: [String: [Request]] = [:]

    func record(_ mediaIDs: Set<String>, reason: MigrationPriorityReason, at date: Date, onPlanAt planURL: URL) {
        guard !mediaIDs.isEmpty else { return }
        lock.withLock {
            requests[Self.key(planURL), default: []].append(Request(mediaIDs: mediaIDs, reason: reason, date: date))
        }
    }

    func requests(madeOnPlanAt planURL: URL) -> [Request] {
        lock.withLock { requests[Self.key(planURL)] ?? [] }
    }

    private static func key(_ planURL: URL) -> String {
        planURL.standardizedFileURL.path
    }
}
