//
//  ShadowPixState.swift
//  shadowpix
//
//  Created by Alexander Freas on 09.11.21.
//

import Foundation

class ShadowPixState: ObservableObject {
    
    static var shared = ShadowPixState()
    
    @Published var selectedKey: ImageKey?
}
