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
    
    private var cancellables = Set<AnyCancellable>()
    @Published var cameraService: CameraService?
    var keyManager: KeyManager
    init(keyManager: KeyManager, fileWriter: FileWriter?) {
        if let fileWriter = fileWriter {
            self.cameraService = CameraService(model: CameraServiceModel(keyManager: keyManager, fileWriter: fileWriter))
        }
        self.keyManager = keyManager
    }
}
