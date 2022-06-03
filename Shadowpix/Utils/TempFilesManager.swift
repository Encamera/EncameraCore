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
    static var shared: TempFilesManager = TempFilesManager()
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
//        NotificationCenter.default
//            .publisher(for: UIApplication.willResignActiveNotification)
//            .sink { _ in
//                try? self.cleanup()
//            }.store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in
                try? self.cleanup()
            }.store(in: &cancellables)

    }
    
    func createTempURL(for mediaType: MediaType, id: String) -> URL {
        let tempUrl = URL(fileURLWithPath: NSTemporaryDirectory(),
                          isDirectory: true).appendingPathComponent(id).appendingPathExtension(mediaType.fileExtension)
        createdTempFiles.insert(tempUrl)
        return tempUrl

    }
    
    deinit {
        try? cleanup()
    }
    
    func deleteItem(at url: URL) {
        guard createdTempFiles.contains(url) else {
            print("Created temp files doesn't contain \(url.absoluteString)")
            return
        }
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
