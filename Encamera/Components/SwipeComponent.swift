//
//  SwipeComponent.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.25.
//

import Foundation
import SwiftUI

// MARK: - Swipe Indicator Component
struct SwipeIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(0.5))
            .frame(width: 36, height: 4)
            .padding(.bottom, 20)
    }
}
