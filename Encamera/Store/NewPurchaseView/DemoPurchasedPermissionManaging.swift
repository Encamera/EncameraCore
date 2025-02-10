import Foundation
import EncameraCore

public class DemoPurchasedPermissionManaging: PurchasedPermissionManaging {
    public var hasEntitlement: Bool = false


    public init() {}
    func requestProducts() async {

    }

    public func isAllowedAccess(feature: AppFeature) -> Bool {
        return false
    }

    public func refreshEntitlements() {
        
    }
}
