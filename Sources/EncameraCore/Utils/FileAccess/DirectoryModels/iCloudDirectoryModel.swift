import Foundation
import Combine

public enum iCloudDownloadStatus {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case cancelled
}

public class iCloudStorageModel: DataStorageModel {

    /// Test seam substituting the ubiquity container root, so the deprecated
    /// iCloud Drive storage can be exercised where no real container exists — unit
    /// tests and simulator UI tests, neither of which has one (`rootURL` would
    /// otherwise point at `unavailableContainerRoot`). Nil in production: the real container is the only
    /// source there, and nothing in the app sets this outside a `UITestMode` hook.
    ///
    /// Setting it also makes `DataStorageAvailabilityUtil.isStorageTypeAvailable(.icloud)`
    /// report `.available`, since the token and container lookup are the production
    /// signal for exactly the same question ("is there a container to read from").
    nonisolated(unsafe) public static var testContainerRootOverride: URL?

    /// Where the ubiquity container is looked up. Production asks `FileManager`;
    /// tests substitute it to simulate states no test host can produce on demand,
    /// such as a signed-in account whose container URL is nil. Replacing it drops
    /// the cached resolution.
    public struct ContainerSource {
        public var hasIdentityToken: () -> Bool
        public var containerURL: () -> URL?

        public init(hasIdentityToken: @escaping () -> Bool, containerURL: @escaping () -> URL?) {
            self.hasIdentityToken = hasIdentityToken
            self.containerURL = containerURL
        }

        public static let fileManager = ContainerSource(
            hasIdentityToken: { FileManager.default.ubiquityIdentityToken != nil },
            containerURL: { FileManager.default.url(forUbiquityContainerIdentifier: nil) }
        )
    }

    nonisolated(unsafe) public static var containerSource: ContainerSource = .fileManager {
        didSet {
            containerLock.lock()
            cachedContainerResolution = nil
            containerLock.unlock()
        }
    }

    private static let containerLock = NSLock()
    /// The outer optional is "not resolved yet"; the inner one is the lookup's result.
    nonisolated(unsafe) private static var cachedContainerResolution: URL??

    /// The container's `Documents` directory, or nil when there is no iCloud account
    /// or the account's container cannot be reached.
    ///
    /// `url(forUbiquityContainerIdentifier:)` can block, so the lookup runs once per
    /// signed-in account (`resolveContainerInBackground` does it off the main thread
    /// at launch) and is cached, nil included. Losing the identity token drops the
    /// cache so a later sign-in is looked up afresh.
    static var containerDocumentsURL: URL? {
        containerLock.lock()
        defer { containerLock.unlock() }
        guard containerSource.hasIdentityToken() else {
            cachedContainerResolution = nil
            return nil
        }
        if let cachedContainerResolution {
            return cachedContainerResolution
        }
        let resolved = containerSource.containerURL()?.appendingPathComponent("Documents")
        cachedContainerResolution = .some(resolved)
        return resolved
    }

    /// Resolves the container on a background queue so the first synchronous reader
    /// (album listing right after unlock) does not do the blocking lookup on the main
    /// thread.
    public static func resolveContainerInBackground() {
        DispatchQueue.global(qos: .utility).async {
            _ = containerDocumentsURL
        }
    }

    /// Whether iCloud Drive storage has a container to read from right now.
    public static var isRootAvailable: Bool {
        testContainerRootOverride != nil || containerDocumentsURL != nil
    }

    /// Stands in for the container when it is unavailable. It sits under a file, so
    /// it can never exist as a directory: reads find nothing and writes fail, rather
    /// than landing in (and being listed twice from) the local Documents directory.
    static let unavailableContainerRoot = URL(fileURLWithPath: "/dev/null", isDirectory: false)
        .appendingPathComponent("UnavailableUbiquityContainer", isDirectory: true)

    /// Never traps: with no container this is `unavailableContainerRoot`. Callers
    /// gate on `isRootAvailable` (or `DataStorageAvailabilityUtil`) before relying on it.
    public static var rootURL: URL {
        if let testContainerRootOverride {
            return testContainerRootOverride
        }
        return containerDocumentsURL ?? unavailableContainerRoot
    }

    public var storageType: StorageType {
        .icloud
    }

    public let album: Album

    required public init(album: Album) {
        self.album = album
    }

    private var localCancellables = Set<AnyCancellable>()
    @MainActor
    private var downloadStatusSubjects = [URL: PassthroughSubject<iCloudDownloadStatus, Never>]()
    @MainActor
    private var downloadTasks = [URL: AnyCancellable]()
    @MainActor
    private var activeQueries = [URL: (NSMetadataQuery, [NSObjectProtocol])]()

    public var baseURL: URL {
        let preferred = iCloudStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent)
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }
        let legacy = iCloudStorageModel.rootURL.appendingPathComponent(album.encryptedPathComponent)
        if FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return preferred
    }

    public func triggerDownloadOfAllFilesFromiCloud() {
        enumeratorForStorageDirectory().forEach({
            try? iCloudFileStatusUtil.startDownload(for: $0)
        })
    }

    public func triggerDownload(ofFile file: EncryptedMedia) {
        guard case .url(let source) = file.source else {
            return
        }
        try? iCloudFileStatusUtil.startDownload(for: source)
    }

    public func resolveDownloadedMedia<T: MediaDescribing>(media: T) throws -> T?  {
        guard let source = media.downloadedSource else {
            return nil
        }
        if FileManager.default.fileExists(atPath: source.path) {
            return T(source: .url(source), generateID: false)
        } else {
            throw DataStorageModelError.couldNotCreateMedia
        }
    }

    @MainActor
    public func checkDownloadStatus<T: MediaDescribing>(ofFile file: T) -> AnyPublisher<iCloudDownloadStatus, Never> {
        guard case .url(let source) = file.source else {
            return Empty().eraseToAnyPublisher()
        }

        if let subject = downloadStatusSubjects[source] {
            return subject.eraseToAnyPublisher()
        } else {
            let subject = PassthroughSubject<iCloudDownloadStatus, Never>()
            downloadStatusSubjects[source] = subject
            Task { @MainActor in
                monitorDownloadProgress(for: source, subject: subject)
            }
            return subject.eraseToAnyPublisher()
        }
    }

    @MainActor
    private func monitorDownloadProgress(for fileURL: URL, subject: PassthroughSubject<iCloudDownloadStatus, Never>) {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemURLKey, fileURL as CVarArg)
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.valueListAttributes = [
            NSMetadataUbiquitousItemPercentDownloadedKey,
            NSMetadataUbiquitousItemDownloadingStatusKey
        ]

        var updateObserver: NSObjectProtocol?
        var gatheringObserver: NSObjectProtocol?
        
        func processItem(_ item: NSMetadataItem) -> Bool {
            // Returns true if download is complete and observer should be terminated
            if let downloadingStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String {
                switch downloadingStatus {
                case NSMetadataUbiquitousItemDownloadingStatusDownloaded,
                     NSMetadataUbiquitousItemDownloadingStatusCurrent:
                    subject.send(.downloaded)
                    subject.send(completion: .finished)
                    return true
                default:
                    if let progress = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double {
                        let percent = progress / 100.0
                        if percent < 1 {
                            subject.send(.downloading(progress: percent))
                        } else if percent >= 1 {
                            subject.send(.downloaded)
                            subject.send(completion: .finished)
                            return true
                        }
                    } else {
                        subject.send(.notDownloaded)
                    }
                }
            }
            return false
        }
        
        let terminateObserver: () -> Void = { [weak self] in
            query.stop()
            if let observer = updateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = gatheringObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            Task { @MainActor [weak self] in
                self?.downloadStatusSubjects.removeValue(forKey: fileURL)
                self?.activeQueries.removeValue(forKey: fileURL)
            }
        }
        
        updateObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] notification in
            guard self != nil else { return }
            
            if let items = notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? NSArray,
               let item = items.firstObject as? NSMetadataItem {
                if processItem(item) {
                    terminateObserver()
                    return
                }
            }
            
            // Fallback: also check query.results directly - important for catching
            // completion status that might not be in the notification's changed items
            query.disableUpdates()
            defer { query.enableUpdates() }
            
            if let item = query.results.first as? NSMetadataItem {
                if processItem(item) {
                    terminateObserver()
                }
            }
        }
        
        // Also observe initial gathering completion - important for files that download quickly
        // or are already downloaded when the query starts
        gatheringObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            guard self != nil else { return }
            query.disableUpdates()
            defer { query.enableUpdates() }
            
            if let item = query.results.first as? NSMetadataItem {
                if processItem(item) {
                    terminateObserver()
                }
            }
        }
        
        var observers: [NSObjectProtocol] = []
        if let observer = updateObserver {
            observers.append(observer)
        }
        if let observer = gatheringObserver {
            observers.append(observer)
        }
        activeQueries[fileURL] = (query, observers)

        query.start()
    }
    public func downloadFileFromiCloud<T: MediaDescribing>(
        media: T,
        progress: @escaping (Double) -> Void
    ) async throws -> T {
        guard media.needsDownload, case .url(let source) = media.source else {
            return media
        }

        try iCloudFileStatusUtil.startDownload(for: source)
        
        let stream = AsyncThrowingStream<iCloudDownloadStatus, Error> { continuation in
            let task = Task { @MainActor in
                let cancellable = self.checkDownloadStatus(ofFile: media)
                    .receive(on: RunLoop.main)
                    .sink(
                        receiveCompletion: { completion in
                            switch completion {
                            case .finished:
                                continuation.finish()
                            case .failure:
                                continuation.finish()
                            }
                        },
                        receiveValue: { status in
                            continuation.yield(status)
                        }
                    )
                self.localCancellables.insert(cancellable)
            }
            
            continuation.onTermination = { @Sendable termination in
                switch termination {
                case .cancelled:
                    task.cancel()
                    Task { @MainActor in
                        self.cleanUpCancellables()
                        if case .url(let sourceURL) = media.source {
                            self.cleanUpQuery(for: sourceURL)
                        }
                    }
                default:
                    break
                }
            }
        }
        
        do {
            for try await status in stream {
                try Task.checkCancellation()
                
                switch status {
                case .notDownloaded:
                    progress(0)
                case .downloading(let progressValue):
                    progress(progressValue)
                case .downloaded:
                    do {
                        if let resolved = try self.resolveDownloadedMedia(media: media) {
                            progress(1)
                            await MainActor.run {
                                self.cleanUpCancellables()
                                if case .url(let sourceURL) = media.source {
                                    self.cleanUpQuery(for: sourceURL)
                                }
                            }
                            return resolved
                        } else {
                            progress(1)
                            await MainActor.run {
                                self.cleanUpCancellables()
                                if case .url(let sourceURL) = media.source {
                                    self.cleanUpQuery(for: sourceURL)
                                }
                            }
                            throw DataStorageModelError.couldNotCreateMedia
                        }
                    } catch {
                        await MainActor.run {
                            self.cleanUpCancellables()
                            if case .url(let sourceURL) = media.source {
                                self.cleanUpQuery(for: sourceURL)
                            }
                        }
                        throw error
                    }
                case .cancelled:
                    await MainActor.run {
                        self.cleanUpCancellables()
                        if case .url(let sourceURL) = media.source {
                            self.cleanUpQuery(for: sourceURL)
                        }
                    }
                    throw CancellationError()
                }
            }
            
            await MainActor.run {
                self.cleanUpCancellables()
                if case .url(let sourceURL) = media.source {
                    self.cleanUpQuery(for: sourceURL)
                }
            }
            throw DataStorageModelError.couldNotCreateMedia
        } catch {
            await MainActor.run {
                self.cleanUpCancellables() 
                if case .url(let sourceURL) = media.source {
                    self.cleanUpQuery(for: sourceURL)
                }
            }
            throw error
        }
    }


    @MainActor
    private func cleanUpCancellables() {
        self.localCancellables.forEach { $0.cancel() }
        self.localCancellables.removeAll()
    }
    
    @MainActor
    private func cleanUpQuery(for url: URL) {
        if let (query, observers) = activeQueries[url] {
            query.stop()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            activeQueries.removeValue(forKey: url)
        }
        downloadStatusSubjects.removeValue(forKey: url)
    }
    @MainActor
    public func cancelDownload(for url: URL) {
        downloadTasks[url]?.cancel()
        downloadTasks.removeValue(forKey: url)
        downloadStatusSubjects[url]?.send(.cancelled)
        downloadStatusSubjects[url]?.send(completion: .finished)
        cleanUpQuery(for: url)
    }
}
