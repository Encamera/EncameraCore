//
//  AppModalEnvironment.swift
//  Encamera
//
//  Created by Alexander Freas on 26.01.25.
//

import Foundation
import SwiftUI

struct AppModalEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppModal? = nil
}

extension EnvironmentValues {
    @Entry var appModal: AppModal?
}
