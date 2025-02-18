import Foundation
import RevenueCat
import EncameraCore

public protocol PurchasedPermissionManaging {
    func refreshEntitlements() async
    func isAllowedAccess(feature: AppFeature) -> Bool
    var hasEntitlement: Bool { get }
}

@MainActor
public class AppPurchasedPermissionUtils: PurchasedPermissionManaging, ObservableObject {


    public var hasEntitlement: Bool = false
    public init() {
        refreshEntitlements()
    }

    public func refreshEntitlements() async {
        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            self.hasEntitlement = !customerInfo.entitlements.active.isEmpty
            EventTracking.setSubscriptionDimensions(
                productID: customerInfo.entitlements.active.first?.value.productIdentifier
            )
        } catch {

        }
    }

    public func refreshEntitlements() {
        Task {
            await refreshEntitlements()
        }
    }

    public func isAllowedAccess(feature: AppFeature) -> Bool {
        refreshEntitlements()
        guard hasEntitlement == false else {
            return true
        }
        switch feature {
        case .accessPhoto(let count) where count <= AppConstants.maxPhotoCountBeforePurchase && count >= 0,
            .createKey(let count) where count < AppConstants.maxPhotoCountBeforePurchase:
            return true
        default:
            return hasEntitlement
        }
    }

}
