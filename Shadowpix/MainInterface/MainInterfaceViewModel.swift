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
    
    @Published var showCameraInterface = false
    private var cancellables = Set<AnyCancellable>()
    var cameraService: CameraServicable?
    init(keyManager: KeyManager) {
        self.cameraService = CameraService(keyManager: keyManager, model: CameraServiceModel())
        keyManager.keyPublisher.sink { key in
            self.showCameraInterface = key != nil
        }.store(in: &cancellables)
    }
}
