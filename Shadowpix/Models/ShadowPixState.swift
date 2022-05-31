//
//  ShadowPixState.swift
//  shadowpix
//
//  Created by Alexander Freas on 09.11.21.
//

import Foundation
import SwiftUI
import Combine


class ShadowPixState: ObservableObject {
    
    
    private(set) var authManager: AuthManager?
    var keyManager: KeyManager
    var fileHandler: iCloudFilesEnumerator?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.keyManager = KeychainKeyManager()
        self.authManager = AuthManager(state: self)
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in
                self.authManager?.deauthorize()
            }.store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { _ in
                self.authManager?.authorize()
            }.store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: UIApplication.willResignActiveNotification)
            .sink { _ in
                self.authManager?.deauthorize()
            }.store(in: &cancellables)

    }

    convenience init(fileHandler: iCloudFilesEnumerator) {
        self.init()
        self.fileHandler = fileHandler

    }
    
    @Published var cameraMode: CameraMode = .photo
    @Published var selectedKey: ImageKey?
    @Published var isAuthorized: Bool = false
    @Published var scannedKey: ImageKey? {
        didSet {
            if scannedKey != nil {
                showScannedKeySheet = true
            }
        }
    }
    @Published var showScannedKeySheet: Bool = false {
        willSet {
            if newValue == false {
                scannedKey = nil
            }
        }
    }
    var tempFilesManager: TempFilesManager = TempFilesManager()
}
