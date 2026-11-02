//
//  ICloudDriveVerifiedDelete.swift
//  EncameraCore
//
//  Deletes one component's file from a CloudKit album's iCloud Drive folder once
//  the server confirms the component's record holds its bytes. It is the only
//  place an iCloud Drive file is deleted because its bytes are in CloudKit, so
//  every caller gets the same checks:
//
//  - the folder's own marker names the album;
//  - the file exists in the folder, as a file or an evicted placeholder;
//  - a fresh `fetchRecordMetadata` finds the record in the album with the file's
//    size (`CloudKitRecordPresence`, the check the migration's source delete
//    uses). The media index is never consulted: it is a cache.
//
//  It works per component, so one half of a Live Photo can go while the other
//  stays. An evicted file is sized from file metadata and removed as it is,
//  never downloaded. It needs no key and reads nothing but file metadata and the
//  folder's marker, so it runs while the phone is locked. It never touches the
//  media's preview, which outlives the iCloud Drive file.
//
//  A viewer or player reads the file only while it loads: a photo is decrypted
//  into memory and a video to a temporary file. A load that loses the race with
//  a delete fails, and its retry reads the record the delete just confirmed.
//

import Foundation

// MARK: - Results

/// Why a verified delete left the file in place.
public enum ICloudDriveVerifiedDeleteSkipReason: Equatable, Sendable {
    /// The server has no record under the component's name.
    case recordMissing
    /// The record belongs to another album.
    case wrongAlbum(owner: String)
    /// The record's size is not the file's size, or the file changed size before
    /// the delete.
    case sizeMismatch
    /// The file's size could not be read, so it cannot be compared with the record.
    case sizeUnknown
    /// The component's file is in the folder in no form.
    case notInFolder
    /// The folder's marker does not confirm the folder belongs to the album.
    case folderNotVerified(ICloudDriveFolderScanSkipReason)
    /// The record name is not `mediaID#type` for a photo or video component.
    case invalidRecordName
}

public enum ICloudDriveVerifiedDeleteResult: Sendable {
    /// Every form of the file in the folder was removed.
    case deleted
    /// Nothing was removed.
    case skipped(ICloudDriveVerifiedDeleteSkipReason)
    /// The record could not be fetched or the file could not be removed. A failed
    /// fetch removes nothing; a failed removal may leave one of two forms behind.
    case failed(Error)
}

// MARK: - File system seam

/// The file operations a verified delete makes. None of them downloads an
/// evicted file.
public protocol ICloudDriveVerifiedDeleteFileSystem: Sendable {
    /// The forms of the file at `url` that exist: `url` itself (downloaded, or
    /// evicted in place) and its `.<name>.icloud` placeholder.
    func existingForms(of url: URL) -> [URL]

    /// Whether the bytes of the file at `url` are on this device.
    func isMaterialized(_ url: URL) -> Bool

    /// The on-disk size of a downloaded file.
    func fileSize(at url: URL) -> Int64?

    /// Each file's size from file metadata, keyed by materialized filename,
    /// whether or not the file is downloaded. `nil` when the metadata cannot be read.
    func metadataSizes(inFolder folder: URL) async -> [String: Int64]?

    /// Removes `url` under a coordinated delete. When `expectedSize` is given, the
    /// file is kept, and `false` returned, if its size inside the coordinated block
    /// differs. Returns `true` when the file is gone.
    func coordinatedRemove(_ url: URL, expectedSize: Int64?) throws -> Bool
}

/// The real file system, sizing evicted files through `ICloudDriveSizing`.
public struct ICloudDriveVerifiedDeleteDiskFileSystem: ICloudDriveVerifiedDeleteFileSystem {

    private let sizing: ICloudDriveSizing

    public init(sizing: ICloudDriveSizing = ICloudDriveSizer()) {
        self.sizing = sizing
    }

    public func existingForms(of url: URL) -> [URL] {
        [url, ICloudPlaceholderName.placeholderURL(forMaterialized: url)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func isMaterialized(_ url: URL) -> Bool {
        ICloudPlaceholderName.isMaterialized(url)
    }

    public func fileSize(at url: URL) -> Int64? {
        url.fileSizeBytes()
    }

    public func metadataSizes(inFolder folder: URL) async -> [String: Int64]? {
        await sizing.logicalSizes(inAlbumDirectory: folder)
    }

    public func coordinatedRemove(_ url: URL, expectedSize: Int64?) throws -> Bool {
        var removed = false
        var removeError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url,
                                                         options: .forDeleting,
                                                         error: &coordinationError) { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                removed = true
                return
            }
            if let expectedSize, coordinatedURL.fileSizeBytes() != expectedSize { return }
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
                removed = true
            } catch {
                removeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let removeError { throw removeError }
        return removed
    }
}

// MARK: - Operation

public struct ICloudDriveVerifiedDelete: Sendable, DebugPrintable {

    private let store: CloudKitMediaStoring
    private let fileSystem: ICloudDriveVerifiedDeleteFileSystem
    private let markerConflictVersions: @Sendable (URL) -> [URL]

    /// - Parameters:
    ///   - store: answers whether the component's record is on the server.
    ///   - fileSystem: reads and removes the folder's files.
    ///   - markerConflictVersions: the URLs of the unresolved conflict versions of
    ///     the folder's marker.
    public init(store: CloudKitMediaStoring,
                fileSystem: ICloudDriveVerifiedDeleteFileSystem = ICloudDriveVerifiedDeleteDiskFileSystem(),
                markerConflictVersions: @escaping @Sendable (URL) -> [URL] = ICloudDriveAlbumMarkerFile.unresolvedConflictVersionURLs(of:)) {
        self.store = store
        self.fileSystem = fileSystem
        self.markerConflictVersions = markerConflictVersions
    }

    /// Deletes the file of the component `recordName` (`mediaID#type`) from
    /// `folder`, the iCloud Drive folder of the CloudKit album `albumID`, once its
    /// record is confirmed on the server in that album with the file's size.
    public func delete(recordName: String, albumID: String, folder: URL) async -> ICloudDriveVerifiedDeleteResult {
        let parsed = MediaRecordName.parse(recordName)
        guard let type = parsed.type, type == .photo || type == .video,
              Self.isPlainFileName(parsed.id) else {
            return skip(recordName, .invalidRecordName)
        }

        if case .failure(let skip) = ICloudDriveFolderScanner.verifiedFolder(folder, albumID: albumID,
                                                                             markerConflictVersions: markerConflictVersions) {
            return self.skip(recordName, .folderNotVerified(skip.reason))
        }

        let fileURL = folder.appendingPathComponent("\(parsed.id).\(type.encryptedFileExtension)", isDirectory: false)
        guard !ICloudDriveAlbumMarkerFile.isMarkerFile(fileURL) else { return skip(recordName, .invalidRecordName) }

        guard !fileSystem.existingForms(of: fileURL).isEmpty else { return skip(recordName, .notInFolder) }

        let isMaterialized = fileSystem.isMaterialized(fileURL)
        guard let sizeBytes = await sourceSize(of: fileURL, in: folder, isMaterialized: isMaterialized) else {
            return skip(recordName, .sizeUnknown)
        }

        let presence: CloudKitRecordPresence
        do {
            presence = try await CloudKitRecordPresence.check(recordName: recordName, albumID: albumID,
                                                              sizeBytes: sizeBytes, store: store)
        } catch {
            printDebug("delete FAILED recordName=\(recordName) — record fetch error=\(error)")
            return .failed(error)
        }
        switch presence {
        case .present: break
        case .absent: return skip(recordName, .recordMissing)
        case .inAnotherAlbum(let owner): return skip(recordName, .wrongAlbum(owner: owner))
        case .sizeMismatch: return skip(recordName, .sizeMismatch)
        }

        for form in fileSystem.existingForms(of: fileURL) {
            let expectedSize = isMaterialized && form == fileURL ? sizeBytes : nil
            do {
                guard try fileSystem.coordinatedRemove(form, expectedSize: expectedSize) else {
                    return skip(recordName, .sizeMismatch)
                }
            } catch {
                printDebug("delete FAILED recordName=\(recordName) removing \(form.lastPathComponent) error=\(error)")
                return .failed(error)
            }
        }
        printDebug("deleted recordName=\(recordName) albumID=\(albumID) sizeBytes=\(sizeBytes) evicted=\(!isMaterialized)")
        return .deleted
    }

    /// The size the record must carry: a downloaded file's size on disk, else the
    /// size file metadata reports, as the migration plan sizes its items. An
    /// evicted file is sized from metadata only; its on-disk size is the
    /// placeholder's.
    private func sourceSize(of url: URL, in folder: URL, isMaterialized: Bool) async -> Int64? {
        if isMaterialized, let size = fileSystem.fileSize(at: url) { return size }
        return await fileSystem.metadataSizes(inFolder: folder)?[url.lastPathComponent]
    }

    private func skip(_ recordName: String,
                      _ reason: ICloudDriveVerifiedDeleteSkipReason) -> ICloudDriveVerifiedDeleteResult {
        printDebug("delete skipped recordName=\(recordName) reason=\(reason)")
        return .skipped(reason)
    }

    /// Whether `name` names a file directly inside a folder.
    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
    }
}
