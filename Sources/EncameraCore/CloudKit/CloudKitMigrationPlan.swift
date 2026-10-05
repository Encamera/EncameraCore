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
import CryptoKit

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
    case failed           // retryable failure recorded in `lastError`
    case skipped          // nothing to migrate (source ciphertext missing) -> terminal

    /// Whether the item needs no further work. `skipped` is terminal too — an item whose
    /// source file is gone has nothing to migrate, so it must not block completion or be
    /// retried forever (which would wedge the whole album).
    public var isDone: Bool { self == .sourceDeleted || self == .skipped }
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
    /// for the record's `createdAt` so gallery ordering survives the move.
    public let createdAt: Date
    public var sizeBytes: Int64
    public var state: MigrationItemState
    /// Long-lived `CKOperation` id — a best-effort resume hint; correctness comes from
    /// the state machine + stable `recordName`, not this.
    public var operationID: String?
    public var lastError: String?
    /// The size of the destination copy when a move back to this device verified
    /// it. The removal pass compares the local file against it before deleting the
    /// record of an item verified in the same run, without asking the server again.
    public var verifiedSizeBytes: Int64?

    public init(mediaID: String,
                recordName: String,
                mediaType: MediaType,
                createdAt: Date,
                sizeBytes: Int64,
                state: MigrationItemState = .pending,
                operationID: String? = nil,
                lastError: String? = nil) {
        self.mediaID = mediaID
        self.recordName = recordName
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
        self.state = state
        self.operationID = operationID
        self.lastError = lastError
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

    public init(albumName: String, storage: StorageType, cloudKitAlbumID: String? = nil) {
        self.albumName = albumName
        self.storage = storage
        self.cloudKitAlbumID = cloudKitAlbumID
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
        MigrationEndpoint(albumName: albumName, storage: storage, cloudKitAlbumID: cloudKitAlbumID)
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
    /// The keys on this device when a `.missingKey` failure was recorded, so a key
    /// added since re-enables automatic resume. Empty for other categories.
    public let heldKeyNames: [KeyName]

    public init(category: Category, date: Date, heldKeyNames: [KeyName] = []) {
        self.category = category
        self.date = date
        self.heldKeyNames = heldKeyNames
    }

    /// Whether launch-time resume should leave the plan alone. A quota failure waits
    /// out `quotaRetryInterval`, a lost account waits for one to be available, and a
    /// missing key waits for a key that was not held at the failure. Every other
    /// failure is retried.
    public func blocksAutomaticResume(now: Date,
                                      isAccountAvailable: Bool,
                                      heldKeyNames current: [KeyName]) -> Bool {
        switch category {
        case .quota:
            return now.timeIntervalSince(date) < Self.quotaRetryInterval
        case .accountUnavailable:
            return !isAccountAvailable
        case .missingKey:
            return Set(current).isSubset(of: Set(heldKeyNames))
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
    public static let currentVersion = 2
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
                      version: version,
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
    public static func album(_ album: Album,
                             items: [MigrationItem],
                             createdAt: Date = Date(),
                             cloudKitAlbumID: String? = nil) throws -> MigrationPlan {
        let destination: StorageType = album.storageOption == .cloudKit ? .local : .cloudKit
        return try MigrationPlan(id: albumPlanID,
                                 source: MigrationEndpoint(album: album),
                                 destination: MigrationEndpoint(albumName: album.name,
                                                                storage: destination,
                                                                cloudKitAlbumID: destination == .cloudKit ? cloudKitAlbumID : nil),
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

// MARK: Progress

    /// Total bytes across every item — the denominator for byte-weighted progress.
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

    /// Bytes whose record is at least `verified` (i.e. durably in CloudKit). Used for
    /// an honest, monotonic progress fraction rather than raw item count.
    public var migratedBytes: Int64 {
        items.reduce(0) { acc, item in
            switch item.state {
            case .verified, .sourceDeleted: return acc + item.sizeBytes
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
    public var fractionComplete: Double {
        guard !items.isEmpty else { return 1 }
        let known = items.lazy.map(\.sizeBytes).filter { $0 > 0 }
        let knownCount = known.count
        let fallbackWeight = knownCount > 0 ? Double(known.reduce(0, +)) / Double(knownCount) : 1
        var done = 0.0
        var total = 0.0
        for item in items {
            let weight = item.sizeBytes > 0 ? Double(item.sizeBytes) : fallbackWeight
            total += weight
            switch item.state {
            case .sourceDeleted, .skipped: done += weight
            case .verified: done += weight * (1 - Self.sourceRemovalShare)
            default: break
            }
        }
        return total > 0 ? min(done / total, 1) : 1
    }

    public var verifiedCount: Int { items.filter { $0.state == .verified || $0.state == .sourceDeleted }.count }
    public var failedCount: Int { items.filter { $0.state == .failed }.count }
    /// Items whose source copy is gone.
    public var sourceDeletedCount: Int { items.filter { $0.state == .sourceDeleted }.count }
    public var skippedCount: Int { items.filter { $0.state == .skipped }.count }

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
            try? FileManager.default.removeItem(at: planURL)
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
        let plaintext = try JSONEncoder().encode(plan)
        let encrypted = try MediaIndexStore.encrypt(plaintext, keyBytes: keyBytes)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encrypted.write(to: url, options: .atomic)
        excludeFromBackup(url)
        if let plan = plan as? MigrationPlan {
            MigrationPlanStore.recordDestination(of: plan, planURL: url)
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
            try FileManager.default.removeItem(at: planURL)
            if Plan.self == MigrationPlan.self {
                MigrationPlanStore.removeDestinationMarker(besidePlanAt: planURL)
            }
            printDebug("delete ok file=\(planURL.lastPathComponent)")
        } catch {
            printDebug("delete FAILED file=\(planURL.lastPathComponent) error=\(error)")
        }
    }

    /// Whether a plan file currently exists on disk.
    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: planURL.path)
    }

    // MARK: - Backup exclusion

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
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

    /// `~/Library/Application Support/CloudKitMigration/` — local, never synced,
    /// excluded from backup.
    static func directoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CloudKitMigration", isDirectory: true)
    }

    /// `CloudKitMigration/<sha256(album.id)>/`. `album.id` includes the storage, so
    /// an album's forward and reverse plans never share a directory.
    static func directoryURL(forSource album: Album) -> URL {
        directoryURL().appendingPathComponent(sourceHash(album), isDirectory: true)
    }

    static func planURL(sourceAlbum: Album, planID: String) -> URL {
        directoryURL(forSource: sourceAlbum).appendingPathComponent("\(planID).encplan")
    }

    /// The album-scope plan's location for `album`.
    static func planURL(for album: Album) -> URL {
        planURL(sourceAlbum: album, planID: MigrationPlan.albumPlanID)
    }

    private static func sourceHash(_ album: Album) -> String {
        sourceHash(albumID: album.id)
    }

    /// The plan directory name for the album whose `Album.id` is `albumID`.
    static func sourceHash(albumID: String) -> String {
        SHA256.hash(data: Data(albumID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Every readable plan whose source is `album`, both scopes. Also removes this
    /// album's checkpoints from the version-1 layout (`<hash>.encplan` and
    /// `moves/<hash>/`), which no longer load.
    public static func plans(for album: Album) async -> [MigrationPlan] {
        removeLegacyCheckpoints(for: album)
        let dir = directoryURL(forSource: album)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var plans: [MigrationPlan] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension == "encplan" {
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
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL(forSource: album).path)) ?? []
        return files.contains { $0.hasSuffix(".encplan") }
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
        let fileManager = FileManager.default
        var carried: [MigrationPlan] = []
        let oldDirectory = directoryURL(forSource: oldAlbum)
        let newDirectory = directoryURL(forSource: newAlbum)
        for file in planFiles(in: oldDirectory) {
            guard let plan = read(at: file, keyBytes: oldAlbum.key.keyBytes),
                  let renamed = try plan.renamingAlbum(oldAlbum.id, to: newAlbum.name) else { continue }
            try write(renamed, to: newDirectory.appendingPathComponent(file.lastPathComponent),
                      keyBytes: newAlbum.key.keyBytes)
            try fileManager.removeItem(at: file)
            removeDestinationMarker(besidePlanAt: file)
            carried.append(renamed)
        }
        if (try? fileManager.contentsOfDirectory(atPath: oldDirectory.path))?.isEmpty == true {
            try? fileManager.removeItem(at: oldDirectory)
        }

        for album in otherAlbums where album.id != oldAlbum.id && album.id != newAlbum.id {
            for file in planFiles(in: directoryURL(forSource: album)) {
                guard let plan = read(at: file, keyBytes: album.key.keyBytes),
                      plan.destination.albumID == oldAlbum.id,
                      let renamed = try plan.renamingAlbum(oldAlbum.id, to: newAlbum.name) else { continue }
                try write(renamed, to: file, keyBytes: album.key.keyBytes)
            }
        }
        return carried
    }

    private static func planFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "encplan" }
    }

    private static func removeLegacyCheckpoints(for album: Album) {
        let hash = sourceHash(album)
        let root = directoryURL()
        try? FileManager.default.removeItem(at: root.appendingPathComponent("\(hash).encplan"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("moves", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true))
    }

    /// Deletes every on-disk migration checkpoint (the encrypted per-file
    /// migration ledgers). Used by the erase flows so user-generated migration
    /// state does not survive a wipe.
    public static func clearAllPlans() throws {
        let dir = directoryURL()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
