import Foundation
import Combine

public enum iCloudDownloadStatus {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case cancelled
}

public class iCloudStorageModel: DataStorageModel {
    public static var rootURL: URL {
        guard let driveURL = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") else {
            fatalError("Could not get drive url")
        }
        return driveURL
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
    private var activeQueries = [URL: (NSMetadataQuery, NSObjectProtocol)]() // Track active queries for cleanup

    public var baseURL: URL {
        return iCloudStorageModel.rootURL.appendingPathComponent(album.encryptedPathComponent)
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

        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] notification in
            guard let items = notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? NSArray,
                  let item = items.firstObject as? NSMetadataItem else {
                return
            }

            func terminateObserver() {
                query.stop()
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                Task { @MainActor in
                    self?.downloadStatusSubjects.removeValue(forKey: fileURL)
                    self?.activeQueries.removeValue(forKey: fileURL)
                }
            }

            if let downloadingStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String {
                switch downloadingStatus {
                case NSMetadataUbiquitousItemDownloadingStatusDownloaded:
                    subject.send(.downloaded)
                    subject.send(completion: .finished)
                    terminateObserver()
                default:
                    if let progress = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double {
                        let percent = progress / 100.0
                        if percent < 1 {
                            subject.send(.downloading(progress: percent))
                        } else if percent == 1 {
                            subject.send(.downloaded)
                        }
                    } else {
                        subject.send(.notDownloaded)
                    }
                }
            }
        }
        
        // Store the query and observer for cleanup on cancellation
        if let observer = observer {
            activeQueries[fileURL] = (query, observer)
        }

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
        
        // Use AsyncThrowingStream to properly handle the callback-based NSMetadataQuery
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
                        // Properly clean up both cancellables AND the NSMetadataQuery
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
        
        // Process the stream until we get a final result
        do {
            for try await status in stream {
                try Task.checkCancellation() // Proper cancellation checking
                
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
            
            // If we get here, the stream ended without a final status
            await MainActor.run {
                self.cleanUpCancellables()
                if case .url(let sourceURL) = media.source {
                    self.cleanUpQuery(for: sourceURL)
                }
            }
            throw DataStorageModelError.couldNotCreateMedia
        } catch {
            // Ensure cleanup happens even if an error is thrown
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
        if let (query, observer) = activeQueries[url] {
            query.stop()
            NotificationCenter.default.removeObserver(observer)
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
