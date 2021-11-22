//
//  ShadowPixState.swift
//  shadowpix
//
//  Created by Alexander Freas on 09.11.21.
//

import Foundation
import SwiftUI

class ShadowPixState: ObservableObject {
    
    static var shared = ShadowPixState()
    
    @Published var selectedKey: ImageKey?
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
