//
//  Form.swift
//  Encamera
//
//  Created by Alexander Freas on 29.09.22.
//

import Foundation
import SwiftUI

extension View {
    
    @ViewBuilder func scrollContentBackgroundColor(_ color: Color) -> some View {
        if #available(iOS 16.0, *) {
            self
                .scrollContentBackground(.hidden)
                .background(color)
        } else {
            self
                .background(color)
        }
    }
}
