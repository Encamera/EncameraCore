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
    init(keyManager: KeyManager) {
        keyManager.keyPublisher.sink { key in
            self.hasKey = key != nil

        }.store(in: &cancellables)
    }
//    init() {
//        _showGalleryView = .constant(false)
//    }
    
}
