//
//  ICloudDriveParitySweep.swift
//  EncameraCore
//
//  Brings a CloudKit album and its linked iCloud Drive folder into parity, in two
//  steps:
//
//  1. Index: the folder scanner (`ICloudDriveFolderScanner.scan`) adds an
//     `.iCloudDrive` component for every file the album's index has no component
//     for, so files an older build added since the last run are listed.
//  2. Sweep: every file in the folder whose component the index places in
//     CloudKit is passed to the verified delete
//     (`ICloudDriveComponentDeleting`). That covers each way a file outlives its
//     upload: the app died between verify and delete, the delete failed, or
//     another device uploaded the item. The sweep makes no checks of its own; it
//     only chooses which components to pass, and the verified delete decides.
//
//  Both steps run on every pass. Once the folder holds no file whose component is
//  in CloudKit and the index lists every file, a pass changes nothing.
//

import Foundation

/// Deletes one component's file from a CloudKit album's iCloud Drive folder once
/// its record is verified on the server. `ICloudDriveVerifiedDelete` is the one
/// implementation; the protocol lets the sweep be tested with a spy.
public protocol ICloudDriveComponentDeleting: Sendable {
    func delete(recordName: String, albumID: String, folder: URL) async -> ICloudDriveVerifiedDeleteResult
}

extension ICloudDriveVerifiedDelete: ICloudDriveComponentDeleting {}

public struct ICloudDriveParitySweep: Sendable, DebugPrintable {

    /// What one pass did.
    public struct Report: Equatable, Sendable {
        /// The folder scan's result.
        public let scan: ICloudDriveFolderScanResult
        /// The component record names passed to the verified delete, sorted.
        public let swept: [String]
        /// Of `swept`, the ones whose file the verified delete removed, sorted.
        public let deleted: [String]

        /// Whether the pass added no index component and passed no file to the
        /// verified delete.
        public var changedNothing: Bool {
            guard swept.isEmpty else { return false }
            if case .scanned(let added, let removed) = scan { return added.isEmpty && removed.isEmpty }
            return true
        }
    }

    private let scanner: ICloudDriveFolderScanner
    private let indexStore: MediaIndexStore
    private let verifiedDelete: ICloudDriveComponentDeleting
    private let fileExists: @Sendable (URL) -> Bool

    /// - Parameters:
    ///   - scanner: the album's folder scanner.
    ///   - indexStore: the album's index, the one the scanner writes.
    ///   - verifiedDelete: deletes a component's file once its record is verified.
    ///   - fileExists: whether a component's file is in the folder, downloaded or
    ///     as an evicted placeholder.
    public init(scanner: ICloudDriveFolderScanner,
                indexStore: MediaIndexStore,
                verifiedDelete: ICloudDriveComponentDeleting,
                fileExists: @escaping @Sendable (URL) -> Bool = { ICloudPlaceholderName.existsInAnyForm($0) }) {
        self.scanner = scanner
        self.indexStore = indexStore
        self.verifiedDelete = verifiedDelete
        self.fileExists = fileExists
    }

    /// Scans `folder`, the iCloud Drive folder linked to the CloudKit album
    /// `albumID`, into the index, then passes every file whose component is in
    /// CloudKit to the verified delete.
    @discardableResult
    public func run(albumID: String, folder: URL) async -> Report {
        let scan = await scanner.scan()
        let entries = await indexStore.reloadFromDisk()?.entries ?? []
        let swept = Self.componentsInCloudKit(entries: entries, folder: folder, fileExists: fileExists)

        var deleted: [String] = []
        for recordName in swept {
            if case .deleted = await verifiedDelete.delete(recordName: recordName, albumID: albumID, folder: folder) {
                deleted.append(recordName)
            }
        }
        printDebug("run albumID=\(albumID) swept=\(swept.count) deleted=\(deleted.count)")
        return Report(scan: scan, swept: swept, deleted: deleted)
    }

    /// The record names of the components `entries` place in CloudKit whose file
    /// is still in `folder`, sorted.
    static func componentsInCloudKit(entries: [MediaIndexEntry],
                                     folder: URL,
                                     fileExists: (URL) -> Bool) -> [String] {
        var recordNames: [String] = []
        for entry in entries {
            for type in [MediaType.photo, .video] {
                let has = type == .photo ? entry.hasPhotoComponent : entry.hasVideoComponent
                let location = type == .photo ? entry.photoLocation : entry.videoLocation
                guard has, location == .cloudKit else { continue }
                let url = folder.appendingPathComponent("\(entry.id).\(type.encryptedFileExtension)", isDirectory: false)
                guard fileExists(url) else { continue }
                recordNames.append(MediaRecordName.componentRecordName(mediaID: entry.id, type: type))
            }
        }
        return recordNames.sorted()
    }
}
