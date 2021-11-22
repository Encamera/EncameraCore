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
    
    func cleanup() throws {
        for file in createdTempFiles {
            try FileManager.default.removeItem(at: file)
        }
    }
    
}
