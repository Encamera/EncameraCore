//
//  CloudKitAlbumMembership.swift
//  EncameraCore
//
//  Two shared guards around whole-album moves:
//
//  - `MigrationPlanStore.planRole(forAlbumID:)`: the one synchronous answer to
//    "is this album in a move, and on which side?". Every guard that must treat a
//    moving album differently asks this, rather than scanning plans itself.
//  - `CloudKitAlbumMembership.members(ofAlbumID:store:uploadQueue:)`: the one check
//    that must pass before the app deletes an `EncAlbum` record. Every `EncMedia`
//    parents to its album with `.deleteSelf`, so deleting an album record deletes
//    every record that still points at it, whether or not this device knows it.
//

import Foundation
import CryptoKit
import CloudKit

// MARK: - Plan role

/// An album's part in a whole-album move between local storage and CloudKit.
/// Item-scope moves (selected media) do not give an album a role: the album itself
/// stays where it is.
public enum MigrationPlanRole: Equatable, Sendable {
    /// No album-scope plan names the album.
    case none
    /// The album is being moved. `isRunning` is true while a run is driving the
    /// plan in this process; false for a plan that is paused, failed or cancelled.
    case source(MigrationDirection, isRunning: Bool)
    /// The album is the twin a move is filling: the CloudKit album a move to
    /// CloudKit lands in, or the local album a move back to this device lands in.
    case destination(MigrationDirection, isRunning: Bool)

    /// Whether new media must be kept out of the album on this device: it is the
    /// source of a running move back to this device. That run deletes the album's
    /// record once it has moved what it planned, and the record takes every media
    /// record still parented to it with it.
    ///
    /// A plan that is not running does not refuse anything: the next run re-reads
    /// the album and checks it for unplanned members before it deletes the record.
    public var refusesNewMedia: Bool {
        if case .source(.toLocal, isRunning: true) = self { return true }
        return false
    }
}

/// Thrown when media is saved or moved into an album whose `MigrationPlanRole`
/// refuses new media.
public enum AlbumMoveGuardError: Error, Equatable, LocalizedError {
    case moveInProgress

    public var errorDescription: String? {
        switch self {
        case .moveInProgress:
            return L10n.CloudKitMigration.saveBlockedMovingToLocal
        }
    }
}

/// The roles of albums whose whole-album run is in flight in this process. Written
/// by `CloudKitMigrationManager` on the main actor; readable from any thread.
final class MigrationRunRoles: @unchecked Sendable {
    static let shared = MigrationRunRoles()

    private let lock = NSLock()
    private var roles: [String: MigrationPlanRole] = [:]

    func role(forAlbumID albumID: String) -> MigrationPlanRole? {
        lock.withLock { roles[albumID] }
    }

    func begin(source: String, destination: String, direction: MigrationDirection) {
        lock.withLock {
            roles[source] = .source(direction, isRunning: true)
            roles[destination] = .destination(direction, isRunning: true)
        }
        Self.postChange()
    }

    func end(source: String, destination: String) {
        lock.withLock {
            roles[source] = nil
            roles[destination] = nil
        }
        Self.postChange()
    }

    private static func postChange() {
        let post = { NotificationCenter.default.post(name: MigrationPlanStore.planRolesDidChange, object: nil) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}

extension EncryptedPlanStore where Plan == MigrationPlan {

    /// Posted on the main thread whenever a whole-album run starts or ends in this
    /// process, so a screen showing `planRole(forAlbumID:)` can refresh.
    public static let planRolesDidChange = Notification.Name("MigrationPlanStore.planRolesDidChange")

    /// The album's part in a whole-album move, from the run in flight in this
    /// process or, failing that, from the plan files on disk. Synchronous and
    /// decrypts nothing: a source is found by its plan directory, a destination by
    /// the hashed marker written beside its source's plan.
    ///
    /// `albumID` is `Album.id` (`"<uuid>_cloudKit"`, `"<name>_local"`, ...).
    public static func planRole(forAlbumID albumID: String) -> MigrationPlanRole {
        if let running = MigrationRunRoles.shared.role(forAlbumID: albumID) {
            return running
        }
        let fileManager = FileManager.default
        let hash = sourceHash(albumID: albumID)
        let ownPlan = directoryURL().appendingPathComponent(hash, isDirectory: true)
            .appendingPathComponent("\(MigrationPlan.albumPlanID).encplan")
        if fileManager.fileExists(atPath: ownPlan.path) {
            return .source(direction(ofSourceAlbumID: albumID), isRunning: false)
        }
        let sourceDirectories = (try? fileManager.contentsOfDirectory(at: directoryURL(),
                                                                      includingPropertiesForKeys: nil)) ?? []
        for directory in sourceDirectories {
            let marker = directory.appendingPathComponent(destinationMarkerName)
            let plan = directory.appendingPathComponent("\(MigrationPlan.albumPlanID).encplan")
            guard let named = try? String(contentsOf: marker, encoding: .utf8),
                  named == hash,
                  fileManager.fileExists(atPath: plan.path) else { continue }
            return .destination(albumID.hasSuffix("_\(StorageType.cloudKit.rawValue)") ? .toCloudKit : .toLocal,
                                isRunning: false)
        }
        return .none
    }

    /// `planRole(forAlbumID:).refusesNewMedia`, answered from the runs in flight
    /// alone: only a running move refuses new media, so the plan files need not be
    /// read. For the save and capture paths, which ask on every item.
    public static func refusesNewMedia(albumID: String) -> Bool {
        MigrationRunRoles.shared.role(forAlbumID: albumID)?.refusesNewMedia ?? false
    }

    /// A move's direction follows from its source: only a CloudKit album moves to local.
    private static func direction(ofSourceAlbumID albumID: String) -> MigrationDirection {
        albumID.hasSuffix("_\(StorageType.cloudKit.rawValue)") ? .toLocal : .toCloudKit
    }

    /// The file beside an album-scope plan naming its destination album by the
    /// SHA-256 of its `Album.id`, the same hash the plan directories are named by.
    static var destinationMarkerName: String { "\(MigrationPlan.albumPlanID).destination" }

    /// Writes or removes the destination marker for the plan saved at `planURL`. A
    /// move to CloudKit has no destination to name until its album id is resolved.
    static func recordDestination(of plan: MigrationPlan, planURL: URL) {
        guard plan.scope == .album else { return }
        let marker = planURL.deletingLastPathComponent().appendingPathComponent(destinationMarkerName)
        guard plan.destination.storage != .cloudKit || plan.destination.cloudKitAlbumID != nil else {
            try? FileManager.default.removeItem(at: marker)
            return
        }
        try? Data(sourceHash(albumID: plan.destination.albumID).utf8).write(to: marker, options: .atomic)
    }

    /// Removes the destination marker beside the plan at `planURL`, if any.
    static func removeDestinationMarker(besidePlanAt planURL: URL) {
        guard planURL.deletingPathExtension().lastPathComponent == MigrationPlan.albumPlanID else { return }
        try? FileManager.default.removeItem(at: planURL.deletingLastPathComponent()
            .appendingPathComponent(destinationMarkerName))
    }
}

// MARK: - Membership check

/// What still points at a CloudKit album: the `EncMedia` records the server holds
/// for it, and the captures on this device still waiting to upload into it.
public struct CloudKitAlbumMembers: Sendable, Equatable {
    public let albumID: String
    public let records: [CloudKitMediaMetadata]
    public let queuedUploads: [CloudKitPendingUpload]

    public init(albumID: String, records: [CloudKitMediaMetadata], queuedUploads: [CloudKitPendingUpload]) {
        self.albumID = albumID
        self.records = records
        self.queuedUploads = queuedUploads
    }

    public var isEmpty: Bool { records.isEmpty && queuedUploads.isEmpty }

    /// Every record name either half names.
    public var recordNames: Set<String> {
        Set(records.map(\.recordName)).union(queuedUploads.map(\.recordName))
    }

    /// The members other than `recordNames`, e.g. the items a move has already
    /// brought home and removed (a removal can still be queued on the server).
    public func excluding(_ recordNames: Set<String>) -> CloudKitAlbumMembers {
        CloudKitAlbumMembers(albumID: albumID,
                             records: records.filter { !recordNames.contains($0.recordName) },
                             queuedUploads: queuedUploads.filter { !recordNames.contains($0.recordName) })
    }
}

/// The check every app-issued `EncAlbum` delete goes through first. A non-empty
/// result means the delete would cascade to media; the caller must not delete.
public enum CloudKitAlbumMembership: DebugPrintable {

    /// The album's members, read from a full zone-changes fetch (strongly
    /// consistent, unlike the `fetchMetadata(albumID:)` query, whose index can lag
    /// a just-saved record) plus this device's upload queue. Throws when the server
    /// cannot answer: absence can only be trusted from a fetch that completed.
    public static func members(ofAlbumID albumID: String,
                               store: CloudKitMediaStoring,
                               uploadQueue: CloudKitUploadQueue = .shared) async throws -> CloudKitAlbumMembers {
        var byRecordName: [String: CloudKitMediaMetadata] = [:]
        var token: CKServerChangeToken?
        var pages = 0
        while true {
            let page = try await store.fetchChanges(since: token)
            pages += 1
            for record in page.changed {
                byRecordName[record.recordName] = record.albumID == albumID ? record : nil
            }
            for recordName in page.deleted { byRecordName[recordName] = nil }
            guard page.moreComing, let next = page.token else { break }
            token = next
        }
        let queued = await uploadQueue.all().filter { $0.albumID == albumID }
        let members = CloudKitAlbumMembers(albumID: albumID,
                                           records: byRecordName.values.sorted { $0.recordName < $1.recordName },
                                           queuedUploads: queued)
        printDebug("members albumID=\(albumID) records=\(members.records.count) queued=\(queued.count) pages=\(pages)")
        return members
    }
}
