//
//  ICloudDriveFileVersions.swift
//  EncameraCore
//
//  The `NSFileVersion` conflict versions of a media file in an iCloud Drive
//  album folder. The file at the item's URL is always its current version
//  (`NSFileVersion.currentVersionOfItem`), so reading the URL reads that
//  version; the conflict versions are separate files iCloud keeps beside it.
//

import Foundation

public protocol ICloudDriveFileVersioning: AnyObject {
    /// The URLs of the unresolved conflict versions of the file at `url`. Empty
    /// for a file with no conflict.
    func unresolvedConflictVersionURLs(of url: URL) -> [URL]

    /// Keeps the current version of the file at `url`: marks every unresolved
    /// conflict version resolved and removes every other version. The file's
    /// contents are not touched.
    func resolveConflicts(keepingCurrentVersionOf url: URL) throws
}

/// `NSFileVersion` on this device.
public final class ICloudDriveFileVersions: ICloudDriveFileVersioning {

    public init() {}

    public func unresolvedConflictVersionURLs(of url: URL) -> [URL] {
        ICloudDriveAlbumMarkerFile.unresolvedConflictVersionURLs(of: url)
    }

    /// Inside one coordinated write, as the album marker file resolves its own
    /// conflicts.
    public func resolveConflicts(keepingCurrentVersionOf url: URL) throws {
        var resolveError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url,
                                                         options: [],
                                                         error: &coordinationError) { writeURL in
            do {
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: writeURL) ?? [] {
                    version.isResolved = true
                }
                try NSFileVersion.removeOtherVersionsOfItem(at: writeURL)
            } catch {
                resolveError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let resolveError { throw resolveError }
    }
}
