//
//  CloudKitMigrationPlan.swift
//  EncameraCore
//
//  The durable checkpoint for a user-initiated local -> CloudKit album migration.
//  A migration is a list of per-file work items, each in a state machine that is
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

// MARK: - Plan

/// The whole migration for one album: its work items plus enough context to be
/// self-describing on disk. Persisted encrypted under
/// `~/Library/Application Support/CloudKitMigration/<sha256(album.id)>.encplan`.
public struct MigrationPlan: Codable, Sendable {
    public static let currentVersion = 1

    public let albumName: String
    /// The album's storage type when the plan was built (`.local`, or `.icloud` for
    /// the chunk-05 reuse). Never `.cloudKit`.
    public let sourceStorage: StorageType
    public var items: [MigrationItem]
    public let createdAt: Date
    public let version: Int
    /// Set when the user explicitly cancels. A cancelled plan is kept on disk (so a
    /// partially-moved album can still be finished by a manual resume, recovering any
    /// already-uploaded item), but launch-time auto-resume skips it — so a cancel is
    /// durable and is never silently restarted in the background. Cleared on re-plan.
    public var cancelledAt: Date?

    public init(albumName: String,
                sourceStorage: StorageType,
                items: [MigrationItem],
                createdAt: Date,
                version: Int = MigrationPlan.currentVersion,
                cancelledAt: Date? = nil) {
        self.albumName = albumName
        self.sourceStorage = sourceStorage
        self.items = items
        self.createdAt = createdAt
        self.version = version
        self.cancelledAt = cancelledAt
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

    /// Byte-weighted fraction in `0...1` (1 when there is no work).
    public var fractionComplete: Double {
        let total = totalBytes
        guard total > 0 else { return 1 }
        return Double(migratedBytes) / Double(total)
    }

    public var verifiedCount: Int { items.filter { $0.state == .verified || $0.state == .sourceDeleted }.count }
    public var failedCount: Int { items.filter { $0.state == .failed }.count }

    /// Whether every item is fully done (`sourceDeleted`).
    public var isComplete: Bool { !items.isEmpty && items.allSatisfy { $0.state.isDone } }

    /// Whether any item still needs work (drives launch-time resume detection).
    public var hasRemainingWork: Bool { items.contains { !$0.state.isDone } }
}

// MARK: - Persistence

/// Reads/writes one album's `MigrationPlan`, encrypted with the album key and
/// written atomically (temp-file + rename via `Data.WritingOptions.atomic`) so a
/// crash mid-write can never corrupt the checkpoint. Keyed by `sha256(album.id)`,
/// matching `MediaIndexStore`, so the cleartext album name never appears on disk.
/// The plan only exists while the album is still its source type, so keying by the
/// source id is stable for the whole migration (the file is deleted on completion).
public actor MigrationPlanStore: DebugPrintable {

    private let keyBytes: [UInt8]
    private let planURL: URL

    public init(album: Album) {
        self.keyBytes = album.key.keyBytes
        self.planURL = Self.planURL(for: album)
    }

    /// Direct initializer for tests, exercising the store without a full `Album`.
    init(keyBytes: [UInt8], planURL: URL) {
        self.keyBytes = keyBytes
        self.planURL = planURL
    }

    /// Loads and decrypts the plan, or `nil` if absent/unreadable/corrupt.
    public func load() -> MigrationPlan? {
        // "absent", "wrong key / corrupt ciphertext" and "decodes but isn't a plan"
        // all returned the same `nil`, so a checkpoint that failed to come back
        // looked identical to never having existed — and the run silently restarted
        // from scratch instead of resuming.
        guard let fileData = try? Data(contentsOf: planURL) else {
            printDebug("load MISS file=\(planURL.lastPathComponent) — no plan file on disk")
            return nil
        }
        guard let plaintext = try? MediaIndexStore.decrypt(fileData, keyBytes: keyBytes) else {
            printDebug("load FAILED file=\(planURL.lastPathComponent) bytes=\(fileData.count) — could not decrypt (wrong key or corrupt)")
            return nil
        }
        guard let plan = try? JSONDecoder().decode(MigrationPlan.self, from: plaintext) else {
            printDebug("load FAILED file=\(planURL.lastPathComponent) — decrypted but did not decode as a MigrationPlan")
            return nil
        }
        printDebug("load ok file=\(planURL.lastPathComponent) items=\(plan.items.count) verified=\(plan.verifiedCount) failed=\(plan.failedCount)")
        return plan
    }

    /// Encrypts and atomically persists the plan. Called after every item transition.
    public func save(_ plan: MigrationPlan) throws {
        let plaintext = try JSONEncoder().encode(plan)
        let encrypted = try MediaIndexStore.encrypt(plaintext, keyBytes: keyBytes)
        try FileManager.default.createDirectory(
            at: planURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encrypted.write(to: planURL, options: .atomic)
        Self.excludeFromBackup(planURL)
        printDebug("save ok file=\(planURL.lastPathComponent) items=\(plan.items.count) verified=\(plan.verifiedCount) failed=\(plan.failedCount)")
    }

    /// Removes the plan file (after the migration completes or is fully reverted).
    public func delete() {
        do {
            try FileManager.default.removeItem(at: planURL)
            printDebug("delete ok file=\(planURL.lastPathComponent)")
        } catch {
            // A checkpoint that outlives its migration is re-offered as resumable
            // work on the next launch, so a failed delete is not cosmetic.
            printDebug("delete FAILED file=\(planURL.lastPathComponent) error=\(error)")
        }
    }

    /// Whether a plan file currently exists on disk.
    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: planURL.path)
    }

    // MARK: File location

    /// `~/Library/Application Support/CloudKitMigration/` — local, never synced,
    /// excluded from backup.
    static func directoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CloudKitMigration", isDirectory: true)
    }

    static func planURL(for album: Album) -> URL {
        let digest = SHA256.hash(data: Data(album.id.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL().appendingPathComponent("\(hash).encplan")
    }

    /// Whether a migration plan already exists on disk for the album.
    public static func hasPlan(for album: Album) -> Bool {
        FileManager.default.fileExists(atPath: planURL(for: album).path)
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

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
