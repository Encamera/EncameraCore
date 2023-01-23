//
//  iCloudDirectoryModel.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation
import Combine

class iCloudStorageModel: DataStorageModel {
    
    var storageType: StorageType {
        .icloud
    }
    
    let keyName: KeyName
    
    required init(keyName: KeyName) {
        self.keyName = keyName
    }
    
    private var localCancellables = Set<AnyCancellable>()
    var baseURL: URL {
        guard let driveURL = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") else {
            fatalError("Could not get drive url")
        }
        
        let destURL = driveURL.appendingPathComponent(keyName)
        return destURL
    }
    
    func triggerDownloadOfAllFilesFromiCloud() {
        enumeratorForStorageDirectory().forEach({
            try? FileManager.default.startDownloadingUbiquitousItem(at: $0)
        })
    }
    
    func resolveDownloadedMedia<T: MediaDescribing>(media: T) throws -> T? where T.MediaSource == URL {
        if FileManager.default.fileExists(atPath: media.downloadedSource.path) {
            if let downloaded = T(source: media.downloadedSource) {
                return downloaded
            } else {
                throw DataStorageModelError.couldNotCreateMedia
            }
        } else {
            return nil
        }
    }
    
    
    func downloadFileFromiCloud<T: MediaDescribing>(media: T, progress: (Double) -> Void) async throws -> T where T.MediaSource == URL {
        guard media.needsDownload == true else {
            return media
        }
        try FileManager.default.startDownloadingUbiquitousItem(at: media.source)        

        return try await withCheckedThrowingContinuation { [weak self] continuation in
            
            let timer = Timer.publish(every: 1, on: .main, in: .default)
                .autoconnect()
            var attempts = 0
            
                timer
                .receive(on: DispatchQueue.main)
                .sink { out in
                    attempts += 1
                    do {
                        if let downloaded = try self?.resolveDownloadedMedia(media: media) {

                            continuation.resume(returning: downloaded)
                            timer.upstream.connect().cancel()
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    if attempts > 20 {
                        timer.upstream.connect().cancel()
                    }
                }.store(in: &localCancellables)
        }

        
    }
}
