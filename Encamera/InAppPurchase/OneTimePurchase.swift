import Foundation
import StoreKit

@dynamicMemberLookup
struct OneTimePurchase: Identifiable, Equatable {
    let product: Product
   
    var id: String { product.id }
    
    init?(product: Product) {
        self.product = product
    }
    
    subscript<T>(dynamicMember keyPath: KeyPath<Product, T>) -> T {
        product[keyPath: keyPath]
    }
    
    var priceText: String {
        "\(self.displayPrice)"
    }
}

