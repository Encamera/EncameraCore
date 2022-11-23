//
//  SubscriptionOptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 04.11.22.
//

import SwiftUI
import StoreKit


struct SubscriptionOptionView: View {
    let subscription: ServiceSubscription
    let savings: SubscriptionSavings?
    @State private var hasFreeTrial: Bool = false
    let isSubscribed: Bool

    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    private var savingsText: String? {
        savings.map { "\($0.formattedPrice(for: subscription)) (Save \($0.formattedPercent))" }
    }
    
    private static var backgroundColor: Color {
        .foregroundSecondary
    }
    
    private static var backgroundShape: some InsettableShape {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }
    
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                
                if isSubscribed {
                    Text( "Subscribed")
                        .fontType(.extraSmall, on: .elevated)
                        .textPill(color: .green)
                } else if hasFreeTrial {
                    Text("Free Trial Available")
                        .fontType(.extraSmall, on: .elevated)
                        .textPill(color: .orange)
                }
                
                
                Text(subscription.displayName)
                    .fontType(.small, weight: .bold)
                    
                 Text(subscription.description)
                    .fontType(.small)
                    .padding(.bottom, 2)
                 Text(applyKerning(to: "/", in: subscription.priceText))
                    .fontType(.small)
                 if let savingsText = savingsText, !isSubscribed {
                     Text(applyKerning(to: "/()", in: savingsText))
                         .fontType(.extraSmall, on: .elevated)
                         .textPill(color: .green)
                 }
            }
            Spacer()
            checkmarkImage
        }
        .onTapGesture {
            isOn.toggle()
        }
        .productCell(isOn: isOn)
        .task {
            let selectedSubscription = subscription.subscriptionInfo
            hasFreeTrial = await selectedSubscription.isEligibleForIntroOffer && selectedSubscription.introductoryOffer != nil
        }
    }
    
    private var checkmarkImage: some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
         .symbolRenderingMode(.palette)
         .foregroundStyle(
             isOn ? Color.green : Color.background,
             Color.clear,
             Color.foregroundPrimary
         )
         .font(.title2)
    }
    
    private func applyKerning(to symbols: String, in text: String, kerningValue: CGFloat = 1.0) -> AttributedString {
        var attributedString = AttributedString(text)
        let characters = symbols.map(String.init)
        
        for character in characters {
            if let range = attributedString.range(of: character) {
                attributedString[range].kern = kerningValue
            }
        }
        return attributedString
    }
}

extension View {
    @ViewBuilder func textPill(color: Color) -> some View {
        self
            .padding(5)
            .background(color)
            .cornerRadius(10)
    }
}


class MockProduct: SKProduct {
    
}
struct SubscriptionOptionView_Previews: PreviewProvider {
    static var previews: some View {
        Text("")
            .preferredColorScheme(.dark)
    }
}
