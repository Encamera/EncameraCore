//
//  ICloudDriveDownloadAhead.swift
//  EncameraCore
//
//  Asks iCloud Drive to download the files the blob migration will move next,
//  before the app goes to the background. A download needs no key and the
//  system carries it on while the app is suspended, so a later background task run
//  finds the bytes on disk and spends its time uploading.
//
//  The batch is the next items `BlobMigrationOrder.next` returns for a locked
//  phone (the work a background task run can do), skipping items whose bytes are
//  already here. It holds at most `ICloudDriveMigrationBatchSize.current` files,
//  and their sizes together must fit in the free disk space less
//  `reservedBytes`; the batch stops at the first file that does not fit. With
//  free space unknown nothing is requested.
//
//  A requested file is recorded, so the blob loop evicts it again when its item
//  does not verify, as it does a file it downloaded itself.
//
//  Off Wi-Fi nothing is requested, like the blob loop. A download iOS has
//  already accepted keeps going if the phone moves to cellular; the app cannot
//  cancel it.
//

import Foundation

@MainActor
public struct ICloudDriveDownloadAhead: DebugPrintable {

    /// Free space the batch leaves untouched.
    public static let reservedBytes: Int64 = 1 << 30

    private static var requested: Set<URL> = []

    /// Whether a download of `url` was requested and the blob loop has not yet
    /// taken it over.
    static func isRequested(_ url: URL) -> Bool {
        requested.contains(url.standardizedFileURL)
    }

    /// Forgets the request for `url`, once the blob loop has taken it over.
    static func removeRequest(_ url: URL) {
        requested.remove(url.standardizedFileURL)
    }

    private let keyCache: BlobMigrationKeyCache
    private let freeSpace: DeviceFreeSpaceProviding
    private let isOnUnmeteredNetwork: () -> Bool
    private let maxFiles: () -> Int
    private let startDownloading: (URL) throws -> Void
    private let linkedFolder: (String) -> URL?
    private let seed: (_ mediaID: String) -> UInt64

    /// - Parameters:
    ///   - keyCache: the keys that open each album's plan; nil for the shared cache.
    ///   - freeSpace: free disk space.
    ///   - isOnUnmeteredNetwork: whether the device is on Wi-Fi, or on any network
    ///     while cellular is allowed; nothing is requested otherwise.
    ///   - maxFiles: the most files one batch requests.
    ///   - startDownloading: requests one evicted file's download; nil for iCloud Drive's.
    ///   - linkedFolder: the iCloud Drive folder an album id is linked to.
    ///   - seed: this device's order within the ordering's encrypting and
    ///     ciphertext-only tiers.
    public init(keyCache: BlobMigrationKeyCache? = nil,
                freeSpace: DeviceFreeSpaceProviding = LiveDeviceFreeSpace(),
                isOnUnmeteredNetwork: @escaping () -> Bool = { ICloudDriveBlobMigrationCellularPreference.permitsTransferNow },
                maxFiles: @escaping () -> Int = { ICloudDriveMigrationBatchSize.current },
                startDownloading: ((URL) throws -> Void)? = nil,
                linkedFolder: @escaping (String) -> URL? = CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID:),
                seed: @escaping (_ mediaID: String) -> UInt64 = BlobMigrationOrder.deviceSeed()) {
        self.keyCache = keyCache ?? .shared
        self.freeSpace = freeSpace
        self.isOnUnmeteredNetwork = isOnUnmeteredNetwork
        self.maxFiles = maxFiles
        self.startDownloading = startDownloading ?? { try ICloudDriveMaterializer.requestDownload(of: $0) }
        self.linkedFolder = linkedFolder
        self.seed = seed
    }

    /// Requests the next batch for every album whose keys are held. Returns the
    /// URLs requested, by album id.
    @discardableResult
    public func requestNextBatchForHeldAlbums() async -> [String: [URL]] {
        var requestedByAlbum: [String: [URL]] = [:]
        for albumID in keyCache.albumIDs {
            guard let folder = linkedFolder(albumID) else { continue }
            let urls = await requestNextBatch(albumID: albumID, folder: folder)
            if !urls.isEmpty { requestedByAlbum[albumID] = urls }
        }
        return requestedByAlbum
    }

    /// Requests the next batch of the album `albumID`, whose files are in
    /// `folder`. Returns the URLs requested.
    @discardableResult
    public func requestNextBatch(albumID: String, folder: URL) async -> [URL] {
        guard isOnUnmeteredNetwork() else {
            printDebug("requested albumID=\(albumID) files=0 — not on Wi-Fi")
            return []
        }
        guard let album = keyCache.album(forAlbumID: albumID),
              let plan = await MigrationPlanStore(iCloudDriveMigrationFrom: album, cloudKitAlbumID: albumID).load(),
              let free = freeSpace.availableBytesForImport() else { return [] }
        var budget = free - Self.reservedBytes
        let limit = maxFiles()
        var urls: [URL] = []
        for item in BlobMigrationOrder.next(items: plan.items, deviceState: .locked, seed: seed)
        where item.state == .pending || item.state == .failed {
            guard urls.count < limit else { break }
            let url = folder.appendingPathComponent("\(item.mediaID).\(item.mediaType.encryptedFileExtension)",
                                                    isDirectory: false)
            guard ICloudPlaceholderName.existsInAnyForm(url), !ICloudPlaceholderName.isMaterialized(url) else { continue }
            guard item.sizeBytes <= budget else { break }
            do {
                try startDownloading(url)
            } catch {
                printDebug("request FAILED file=\(url.lastPathComponent) error=\(error)")
                continue
            }
            budget -= item.sizeBytes
            urls.append(url)
            Self.requested.insert(url.standardizedFileURL)
        }
        printDebug("requested albumID=\(albumID) files=\(urls.count)")
        return urls
    }

    /// Requests the next batch for every held album each time the app enters the
    /// background. Call once.
    public static func observeBackgrounding(_ makeDownloadAhead: @escaping @MainActor () -> ICloudDriveDownloadAhead = { ICloudDriveDownloadAhead() }) {
        NotificationCenter.default.addObserver(forName: AppLifecycleNotification.didEnterBackground,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in
                // Held open so the requests go out before the app is suspended.
                let assertion = BackgroundExecution.begin(name: "ICloudDriveDownloadAhead")
                await makeDownloadAhead().requestNextBatchForHeldAlbums()
                BackgroundExecution.end(assertion)
            }
        }
    }
}
