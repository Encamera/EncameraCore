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
    }
    
    func createTemporaryMovieUrl() -> URL {
        let movieUrl = URL(fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true).appendingPathComponent("currentMovie.mov")
        createdTempFiles.insert(movieUrl)
        return movieUrl
    }
    
    func createLivePhotoiCloudMovieCaptureUrl() throws -> URL {
        let destinationURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents")
        let temporaryDirectoryURL = try FileManager.default.url(for: .itemReplacementDirectory,
                                                                   in: .userDomainMask,
                                                                   appropriateFor: destinationURL,
                                                                   create: true)
        let url = temporaryDirectoryURL.appendingPathComponent("livephoto")
        createdTempFiles.insert(url)
        return url

    }
    
    deinit {
        try? cleanup()
    }
    
    func cleanup() throws {
        var undeletedFiles = createdTempFiles
        createdTempFiles.forEach { url in
            do {
                try FileManager.default.removeItem(at: url)
                print("Deleted file at \(url.absoluteString)")
                undeletedFiles.remove(url)
            } catch {
                print("Could not delete item at url: \(url)", error)
            }
        }
        createdTempFiles = undeletedFiles
    }
    
}
