//
//  TempFilesManager.swift
//  Encamera
//
//  Created by Alexander Freas on 22.11.21.
//

import Foundation
import UIKit
import Combine

class TempFilesManager {
    static var shared: TempFilesManager = TempFilesManager()

    private var createdTempFiles = Set<URL>()
    private var cancellables = Set<AnyCancellable>()
    private var tempUrl = URL(fileURLWithPath: NSTemporaryDirectory(),
                              isDirectory: true)
    
    init(subdirectory: String) {
        self.tempUrl = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true).appendingPathComponent(subdirectory)
        try! FileManager.default.createDirectory(at: tempUrl, withIntermediateDirectories: true)
    }
    
    init() {
//        NotificationCenter.default
//            .publisher(for: UIApplication.didFinishLaunchingNotification)
//            .sink { _ in
//                try? self.cleanup()
//            }.store(in: &cancellables)
//        NotificationCenter.default
//            .publisher(for: UIApplication.didEnterBackgroundNotification)
//            .sink { _ in
//                try? self.cleanup()
//            }.store(in: &cancellables)
    }
    
    func createTempURL(for mediaType: MediaType, id: String) -> URL {
        let path = tempUrl.appendingPathComponent(id).appendingPathExtension(mediaType.fileExtension)
        createdTempFiles.insert(path)
        return path
    }
    
    deinit {
        try? cleanup()
    }
    
    
    
    func cleanup() throws {
        guard let enumerator = FileManager.default.enumerator(at: tempUrl, includingPropertiesForKeys: nil) else {
            return
        }
        try enumerator.forEach { file in
            guard let url = file as? URL else {
                return
            }
            try FileManager.default.removeItem(at: url)
        }
    }
    
}
