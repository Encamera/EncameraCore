//
//  RoundedCorners.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.25.
//

import Foundation
import SwiftUI
// Custom shape for rounded corners
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
