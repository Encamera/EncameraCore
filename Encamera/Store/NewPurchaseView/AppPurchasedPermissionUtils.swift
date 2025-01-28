import Foundation
import RevenueCat
import EncameraCore

public protocol PurchasedPermissionManaging {
    func isAllowedAccess(feature: AppFeature) -> Bool
    var hasEntitlement: Bool { get }
}

@MainActor
public class AppPurchasedPermissionUtils: PurchasedPermissionManaging, ObservableObject {


    public var hasEntitlement: Bool = false
    public init() {
        Task {
            do {
                let customerInfo = try await Purchases.shared.customerInfo()
                self.hasEntitlement = !customerInfo.entitlements.active.isEmpty
            } catch {

            }
        }
    }

    public func isAllowedAccess(feature: AppFeature) -> Bool {
        switch feature {
        case .accessPhoto(let count) where count <= AppConstants.maxPhotoCountBeforePurchase && count >= 0,
            .createKey(let count) where count < AppConstants.maxPhotoCountBeforePurchase:
            return true
        default:
            return hasEntitlement
        }
    }

}
