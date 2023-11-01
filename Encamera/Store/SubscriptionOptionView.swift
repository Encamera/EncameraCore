//
//  SubscriptionOptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 04.11.22.
//

import SwiftUI
import StoreKit
import EncameraCore


struct SubscriptionOptionView: View {
    let subscription: ServiceSubscription
    let savings: SubscriptionSavings?
    let isSubscribed: Bool

    @Binding var isOn: Bool
    
    private static var backgroundColor: Color {
        .black
    }
    
    private static var backgroundShape: some InsettableShape {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }
    
    var body: some View {
        VStack {
            
            OptionItemView(
                title: subscription.displayName,
                description: savings == nil ? nil : subscription.description,
                isAvailable: true,
                isSelected: $isOn
            ) {
                VStack {

                    if let savings {
                        Text(savings.formattedMonthlyPrice(for: subscription))
                            .fontType(.pt14,
                                      on: isOn ? .lightBackground : .darkBackground,
                                      weight: .bold)
                        Text(savings.formattedTotalSavings(for: subscription))
                            .fontType(.pt10, on: isOn ? .darkBackground : .lightBackground, weight: .bold)
                            .textPill(color: isOn ? .black : .white)
                    } else {
                        Text(subscription.priceText)
                            .fontType(.pt14,
                                      on: isOn ? .lightBackground : .darkBackground,
                                      weight: .bold)

                    }
                }
            }
        }
        .onTapGesture {
            isOn.toggle()
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
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .background(color)
            .cornerRadius(40)
    }
}


