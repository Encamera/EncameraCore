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
    
    static var shared = ShadowPixState()
    
    private(set) var authManager: AuthManager?
    private var cancellables = Set<AnyCancellable>()

    init() {
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
    
    @Published var selectedKey: ImageKey? {
        willSet {
            guard let newKey = newValue else {
                return
            }
            WorkWithKeychain.setKey(key: newKey)
        }
    }
    @Published var isAuthorized: Bool = false {
        didSet {
            WorkWithKeychain.isAuthorized = isAuthorized
        }
    }
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
