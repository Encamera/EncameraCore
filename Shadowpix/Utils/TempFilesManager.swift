//
//  TempFilesManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 22.11.21.
//

import Foundation
import UIKit
import Combine

class TempFilesManager {
    
    private var createdTempFiles = Set<URL>()
    private var cancellables = Set<AnyCancellable>()

    init() {
//        let pub1 = NotificationCenter.default
//            .publisher(for: UIApplication.didFinishLaunchingNotification)
//        let pub2 = NotificationCenter.default
//            .publisher(for: UIApplication.willResignActiveNotification)
//        [pub1, pub2].redu
        NotificationCenter.default
            .publisher(for: UIApplication.didFinishLaunchingNotification)
            .sink { _ in
                try? self.cleanup()
            }.store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: UIApplication.willResignActiveNotification)
            .sink { _ in
                try? self.cleanup()
            }.store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in
                try? self.cleanup()
            }.store(in: &cancellables)

    }
    
    static func createTempURL<T: MediaDescribing>(media: T) -> URL {
        return URL(fileURLWithPath: NSTemporaryDirectory(),
                          isDirectory: true).appendingPathComponent(NSUUID().uuidString + media.mediaType.path)

    }
    
    func createTemporaryMovieUrl() -> URL {
        let movieUrl = URL(fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true).appendingPathComponent(NSUUID().uuidString + "_currentMovie.mov")
        createdTempFiles.insert(movieUrl)
        return movieUrl
    }
    
    func createLivePhotoiCloudMovieCaptureUrl(photoId: String) throws -> URL {
        let destinationURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents")
        let temporaryDirectoryURL = try FileManager.default.url(for: .itemReplacementDirectory,
                                                                   in: .userDomainMask,
                                                                   appropriateFor: destinationURL,
                                                                   create: true)
        let url = temporaryDirectoryURL.appendingPathComponent("\(photoId).livephoto")
        createdTempFiles.insert(url)
        return url

    }
    
    deinit {
        try? cleanup()
    }
    
    func deleteItem(at url: URL) {
        var undeletedFiles = createdTempFiles

        do {
            try FileManager.default.removeItem(at: url)
            print("Deleted file at \(url.absoluteString)")
            undeletedFiles.remove(url)
        } catch {
            print("Could not delete item at url: \(url)", error)
        }
        createdTempFiles = undeletedFiles
    }
    
    func cleanup() throws {
        let filesToDelete = createdTempFiles
        filesToDelete.forEach { url in
            deleteItem(at: url)
        }
    }
    
}
