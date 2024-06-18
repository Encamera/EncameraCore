//
//  BackgroundRectangle.swift
//  Encamera
//
//  Created by Alexander Freas on 18.06.24.
//

import Foundation
import SwiftUI

struct BackgroundRectangle: View {
    var cornerRadius: CGFloat
    var opacity: Double
    var color: Color = .clear

    var body: some View {

        Rectangle()
            .foregroundColor(.clear)
            .background(color.opacity(opacity))
            .cornerRadius(cornerRadius)

    }
}
