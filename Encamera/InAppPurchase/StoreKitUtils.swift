//
//  StoreKitUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 12.10.22.
//

import Foundation
import StoreKit

enum RenewalFrequency: String {
    case monthly
    case yearly
    
}

enum EncameraSubscription: CaseIterable {
    static var allCases: [EncameraSubscription] = [.unlimitedPhotosAndKeys(.yearly), .unlimitedPhotosAndKeys(.monthly)]
    
    static var allProductIDs: Set<String> {
        Set(allCases.map({$0.productId}))
    }
    
    private static let unlimitedPhotosAndKeysString = "unlimitedphotosandkeys"
    
    case unlimitedPhotosAndKeys(RenewalFrequency)
    
    var productId: String {
        var frequency: RenewalFrequency
        var subscription: String
        switch self {
        case .unlimitedPhotosAndKeys(let renewalFrequency):
            subscription = Self.unlimitedPhotosAndKeysString
            frequency = renewalFrequency
        }
        return "subscription.\(frequency).\(subscription)"
    }
    
    init?(product: Product) {
        let components = product.id.components(separatedBy: ".")
        let frequencyString = components[1]
        let subscriptionString = components[2]
        
        guard let frequency = RenewalFrequency(rawValue: frequencyString), subscriptionString == Self.unlimitedPhotosAndKeysString else {
            
                return nil
        }
        self = .unlimitedPhotosAndKeys(frequency)
    }
}

extension Product {
    
    var encameraSubscription: EncameraSubscription? {
        EncameraSubscription(product: self)
    }
}

enum AppFeature {
    case accessPhoto(count: Double)
    case createKey(count: Double)
}

private enum PurchaseConstants {
    static let maxPhotoCountBeforePurchase: Double = 5
}

protocol PurchasedPermissionManaging {
    func isAllowedAccess(feature: AppFeature) -> Bool
}

class AppPurchasedPermissionUtils: PurchasedPermissionManaging, ObservableObject {
    
    let products = EncameraSubscription.allCases.map({$0.productId})
    let subscriptionController = StoreActor.shared.subscriptionController
    init() {
    }
    
    
    @MainActor
    func isAllowedAccess(feature: AppFeature) -> Bool {
        print("Hiiii")
        switch feature {
        case .accessPhoto(let count) where count < PurchaseConstants.maxPhotoCountBeforePurchase, .createKey(let count) where count < PurchaseConstants.maxPhotoCountBeforePurchase:
            return true
        default:
            return subscriptionController.entitledSubscriptionID != nil
        }
    }
}

struct StoreKitUtils {
    
    func isPhotoSubscriptionActive() -> Bool {
        return false
    }
}
