//
//  StorePurchaseController.swift
//  Encamera
//
//  Created by Alexander Freas on 19.11.22.
//

import Foundation
import StoreKit
import Combine

@MainActor
final class StoreProductController: ObservableObject {
    @Published public var products: [OneTimePurchase] = []
    @Published public private(set) var isEntitled: Bool = false
    @Published public private(set) var purchaseError: (any LocalizedError)?
    
    private let productID: String
    
    internal nonisolated init() {
        self.productID = "purchase.lifetimeunlimitedbasic"
        Task(priority: .background) {
            await self.updateEntitlement()
        }
    }
    
    func purchase() async -> PurchaseFinishedAction {
        let action: PurchaseFinishedAction
        guard let product = products.first else {
            print("Product has not loaded yet")
            return .noAction
        }
        do {
            let result = try await product.product.purchase()
            switch result {
            case .success(let verificationResult):
                let transaction = try verificationResult.payloadValue
                self.isEntitled = true
                await transaction.finish()
            case .pending:
                print("Purchase pending user action")
            case .userCancelled:
                print("User cancelled purchase")
            @unknown default:
                print("Unknown result: \(result)")
            }
            action = .noAction
        } catch let error as LocalizedError {
            purchaseError = error
            action = .displayError
        } catch {
            print("Purchase failed: \(error)")
            action = .noAction
        }
        await updateEntitlement()
        return action

    }
    
    internal func set(isEntitled: Bool) {
        self.isEntitled = isEntitled
    }
    
    private func updateEntitlement() async {
        switch await StoreKit.Transaction.currentEntitlement(for: productID) {
        case .verified: isEntitled = true
        case .unverified(_, let error):
            print("Unverified entitlement for \(productID): \(error)")
            fallthrough
        case .none: isEntitled = false
        }
    }
    
}
