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
    private let tempUrl = URL(fileURLWithPath: NSTemporaryDirectory(),
                              isDirectory: true)
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
        let path = tempUrl.appendingPathComponent(id).appendingPathExtension(mediaType.fileExtension)
        createdTempFiles.insert(path)
        return path

    }
    
    deinit {
        try? cleanup()
    }
    
    func delete<T: MediaDescribing>(media: T) where T.MediaSource == URL {
        deleteItem(at: media.source)
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
        guard let enumerator = FileManager.default.enumerator(atPath: tempUrl.path) else {
            return
        }
        try enumerator.compactMap { item in
            guard let itemUrl = item as? URL else {
                return nil
            }
            return itemUrl
        }
        .forEach { file in
            try FileManager.default.removeItem(at: file)
        }
    }
    
}
