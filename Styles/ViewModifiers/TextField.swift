//
//  TextField.swift
//  Encamera
//
//  Created by Alexander Freas on 24.09.22.
//

import Foundation
import SwiftUI

extension View {
    
    func noAutoModification() -> some View {
        self
            .disableAutocorrection(true)
            .textInputAutocapitalization(.never)
    }
}
