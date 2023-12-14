//
//  NavigationPath.swift
//  Encamera
//
//  Created by Alexander Freas on 14.12.23.
//

import Foundation
import SwiftUI

struct NavigationPathEnvironmentKey: EnvironmentKey {
    static let defaultValue: () -> () = {}
}

extension EnvironmentValues {
    var popLastView: () -> () {
        get { self[NavigationPathEnvironmentKey.self] }
        set { self[NavigationPathEnvironmentKey.self] = newValue }
    }
}
