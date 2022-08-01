//
//  Rotation.swift
//  Encamera
//
//  Created by Alexander Freas on 10.07.22.
//

import Foundation
import SwiftUI
//
struct RotationEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0.0
}

extension EnvironmentValues {
    var rotationFromOrientation: CGFloat {
        get { self[RotationEnvironmentKey.self] }
        set { self[RotationEnvironmentKey.self] = newValue }
    }
}
