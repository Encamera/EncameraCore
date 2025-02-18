//
//  TextPillModifier.swift
//  Encamera
//
//  Created by Alexander Freas on 18.02.25.
//

import Foundation
import SwiftUI

extension View {
    @ViewBuilder func textPill(color: Color) -> some View {
        self
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .background(color)
            .cornerRadius(40)
    }
}
