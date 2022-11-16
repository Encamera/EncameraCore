//
//  StoreActor.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import StoreKit

@globalActor actor StoreActor {
    static let unlimitedMonthlyID = "subscription.monthly.unlimitedkeysandphotos"
    static let unlimitedYearlyID = "subscription.yearly.unlimitedkeysandphotos"
    
    static let subscriptionIDs: Set<String> = [
        unlimitedMonthlyID,
        unlimitedYearlyID
    ]
    
    static let allProductIDs: Set<String> = {
        var ids = subscriptionIDs
        return ids
    }()
    
    static let shared = StoreActor()
    
    private var loadedProducts: [String: Product] = [:]
    private var lastLoadError: Error?
    private var productLoadingTask: Task<Void, Never>?
    
    private var transactionUpdatesTask: Task<Void, Never>?
    private var statusUpdatesTask: Task<Void, Never>?
    private var storefrontUpdatesTask: Task<Void, Never>?
    private var paymentQueue = SKPaymentQueue()

    nonisolated let subscriptionController: StoreSubscriptionController
    
    init() {
        self.subscriptionController = StoreSubscriptionController(productIDs: Array(Self.subscriptionIDs))
        Task(priority: .background) {
            await self.setupListenerTasksIfNecessary()
            await self.loadProducts()
        }
    }
    
    func product(identifiedBy productID: String) async -> Product? {
        await waitUntilProductsLoaded()
        return loadedProducts[productID]
    }
    
    func presentCodeRedemptionSheet() {
        paymentQueue.presentCodeRedemptionSheet()
    }
    
    private func setupListenerTasksIfNecessary() {
        if transactionUpdatesTask == nil {
            transactionUpdatesTask = Task(priority: .background) {
                for await update in StoreKit.Transaction.updates {
                    await self.handle(transaction: update)
                }
            }
        }
        if statusUpdatesTask == nil {
            statusUpdatesTask = Task(priority: .background) {
                for await update in Product.SubscriptionInfo.Status.updates {
                    await subscriptionController.handle(update: update)
                }
            }
        }
        if storefrontUpdatesTask == nil {
            storefrontUpdatesTask = Task(priority: .background) {
                for await update in Storefront.updates {
                    self.handle(storefrontUpdate: update)
                }
            }
        }
    }
    
    private func waitUntilProductsLoaded() async {
        if let task = productLoadingTask {
            await task.value
        }
        // You load all the products at once, so you can skip this if the
        // dictionary is empty.
        else if loadedProducts.isEmpty {
            let newTask = Task {
                await loadProducts()
            }
            productLoadingTask = newTask
            await newTask.value
        }
    }
    
    private func loadProducts() async {
        do {
            let products = try await Product.products(for: Self.allProductIDs)
            try Task.checkCancellation()
            print("Loaded \(products.count) products")
            loadedProducts = products.reduce(into: [:]) {
                $0[$1.id] = $1
            }
            Task(priority: .utility) { @MainActor in
                self.subscriptionController.subscriptions = products
                    .compactMap { ServiceSubscription(subscription: $0) }
                // Now that you have loaded the products, have the subscription
                // controller update the entitlement based on the group ID.
                await self.subscriptionController.updateEntitlement()
            }
        } catch {
            print("Failed to get in-app products: \(error)")
            lastLoadError = error
        }
        productLoadingTask = nil
    }
    
    private func handle(transaction: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = transaction else {
            print("Received unverified transaction: \(transaction)")
            return
        }
        // If you have a subscription, call checkEntitlement() which gets the
        // full status instead.
        if transaction.productType == .autoRenewable {
            await subscriptionController.updateEntitlement()
        }
        await transaction.finish()
    }
    
    private func handle(storefrontUpdate newStorefront: Storefront) {
        print("Storefront changed to \(newStorefront)")
        // Cancel existing loading task if necessary.
        if let task = productLoadingTask {
            task.cancel()
        }
        // Load products again.
        productLoadingTask = Task(priority: .utility) {
            await self.loadProducts()
        }
    }
    
}

extension StoreKit.Transaction {
    var isRevoked: Bool {
        // The revocation date is never in the future.
        revocationDate != nil
    }
}
