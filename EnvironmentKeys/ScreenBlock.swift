//
//  ScreenBlock.swift
//  Encamera
//
//  Created by Alexander Freas on 29.08.22.
//

import Foundation
import SwiftUI

struct ScreenBlockEnvironmentKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var isScreenBlockingActive: Bool {
        get { self[ScreenBlockEnvironmentKey.self] }
        set { self[ScreenBlockEnvironmentKey.self] = newValue }
    }
}
