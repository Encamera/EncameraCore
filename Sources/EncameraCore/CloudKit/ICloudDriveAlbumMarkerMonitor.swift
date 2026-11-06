//
//  ICloudDriveAlbumMarkerMonitor.swift
//  EncameraCore
//
//  Watches iCloud Drive for album marker files (`ICloudDriveAlbumMarkerFile`):
//  one arriving from another device, changing, or finishing its download. Each
//  change calls `onChange`, which runs the walk of the album folders.
//
//  An `NSMetadataQuery` in the ubiquitous documents scope, matched on the
//  marker's file name in either form. Without a ubiquity container the query
//  reports nothing and `onChange` is never called.
//

import Foundation

public final class ICloudDriveAlbumMarkerMonitor: @unchecked Sendable, DebugPrintable {

    /// Called on the main queue after the first gather and after every update.
    public var onChange: (@Sendable () -> Void)?

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    @MainActor
    public func start() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@ OR %K == %@",
                                      NSMetadataItemFSNameKey, ICloudDriveAlbumMarkerFile.fileName,
                                      NSMetadataItemFSNameKey, ICloudDriveAlbumMarkerFile.placeholderFileName)
        query.valueListAttributes = [NSMetadataUbiquitousItemDownloadingStatusKey]
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                self?.onChange?()
            })
        }
        self.query = query
        query.start()
        printDebug("start ok")
    }
}
