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
    
    
    private(set) var authManager: AuthManager
    var keyManager: KeyManager
    var fileAccess: DiskFileAccess<iCloudFilesDirectoryModel>?
    private var cancellables = Set<AnyCancellable>()
    @Published var cameraMode: CameraMode = .photo
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
    var tempFilesManager: TempFilesManager = TempFilesManager.shared

    init() {
        
        self.authManager = AuthManager()
        self.keyManager = MultipleKeyKeychainManager(isAuthorized: self.authManager.$isAuthorized.eraseToAnyPublisher())
        self.keyManager.keyPublisher.sink { newKey in
            guard let key = newKey else {
                return
            }
            self.fileAccess = DiskFileAccess<iCloudFilesDirectoryModel>(key: key)
        }.store(in: &cancellables)
        
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in
                self.authManager.deauthorize()
            }.store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { _ in
                self.authManager.authorize()
            }.store(in: &cancellables)
    }
    
}
