//
//  StoreKitTestingApp.swift
//  StoreKitTesting
//
//  Created by Alexander Freas on 30.10.23.
//

import SwiftUI

@main
struct StoreKitTestingApp: App {
    var body: some Scene {
        WindowGroup {
            PurchaseUpgradeView()
                .preferredColorScheme(.dark)
        }
    }
}
