//
//  PurchasedPermissionManaging.swift
//  EncameraCore
//
//  Created by AI Assistant
//

import Foundation

public protocol PurchasedPermissionManaging {
    func isAllowedAccess(feature: AppFeature) -> Bool
    var hasEntitlement: Bool { get }
    func hasLifetimeUnlimitedSubscription() async -> Bool
}
