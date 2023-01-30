//
//  PurchaseOptionViewModifier.swift
//  Encamera
//
//  Created by Alexander Freas on 23.11.22.
//

import SwiftUI
import StoreKit

struct PurchaseOptionViewModifier: ViewModifier {
    
    private static var backgroundColor: Color {
        .foregroundSecondary
    }
    
    private static var backgroundShape: some InsettableShape {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }
    
    let isOn: Bool
    let product: Product?
    @State private var hasFreeTrial: Bool = false

    func body(content: Content) -> some View {
        VStack {
            if let product = product,  product.isFamilyShareable == true || hasFreeTrial {
                HStack(spacing: 0) {
                    if product.isFamilyShareable {
                        Color.orange.overlay {
                            Text(L10n.familyShareable)
                        }
                    }
                    if hasFreeTrial {
                        
                        Color.green.overlay {
                            Text(L10n.freeTrial)
                        }
                        
                    }
                }
                .foregroundColor(.foregroundSecondary)
                .fontType(.small, weight: .bold).frame(height: 25)
            }
            content.padding()
        }.task {
            guard let selectedSubscription = product?.subscription else {
                return
            }
            hasFreeTrial = await selectedSubscription.isEligibleForIntroOffer && selectedSubscription.introductoryOffer != nil
        }
        
            .frame(maxWidth: .infinity)
            .background(Self.backgroundColor, in: Self.backgroundShape)
            .clipShape(Self.backgroundShape)
            .overlay {
                Self.backgroundShape
                    .strokeBorder(
                        Color.accentColor,
                        lineWidth: isOn ? 1 : 0
                    )
            }
            .fontType(.small)
    }
}

extension View {
    func productCell(product: Product? = nil, isOn: Bool = false) -> some View {
        self.modifier(PurchaseOptionViewModifier(isOn: isOn, product: product))
    }
}
