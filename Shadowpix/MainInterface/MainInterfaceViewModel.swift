//
//  MainInterfaceViewModel.swift
//  Shadowpix
//
//  Created by Alexander Freas on 28.11.21.
//

import Foundation
import SwiftUI
import Combine

class MainInterfaceViewModel: ObservableObject {
    
    @Published var showGalleryView: Bool = false
    @Published var showingKeySelection = false
    @Published var hasKey = false
    private var cancellables = Set<AnyCancellable>()
    @Published var cameraService: CameraService?
    init(keyManager: KeyManager) {
        self.cameraService = CameraService(keyManager: keyManager)

        keyManager.keyPublisher.sink { key in
            self.hasKey = key != nil
            let fileWriter = DiskFileAccess<iCloudFilesDirectoryModel>(key: key)
            self.cameraService?.fileWriter = fileWriter
        }.store(in: &cancellables)
    }
//    init() {
//        _showGalleryView = .constant(false)
//    }
    
}
