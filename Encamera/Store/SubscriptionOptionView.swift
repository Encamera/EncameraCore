//
//  SubscriptionOptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 04.11.22.
//

import SwiftUI
import StoreKit
import EncameraCore

private struct MostPopularIndicatorViewModifier: ViewModifier {
    let popularWidth: CGFloat = 113.0
    let popularHeight: CGFloat = 22.0

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {

            Rectangle()
                          .foregroundColor(.clear)
                          .frame(width: popularWidth * 1.1, height: popularHeight)
                          .background(Color.purchasePopularBackgroundShapeColor)
//                          .background(Color(red: 0.52, green: 0.17, blue: 0.06))
                          .cornerRadius(4)
                          .offset(.init(width: 0.0, height: popularHeight / -2))

            content
            HStack(spacing: 10) {
                Text(L10n.mostPopular)
                    .font(Font.custom("Satoshi Variable", size: 10).weight(.black))
                    .foregroundColor(.white)
            }
            .padding(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .frame(width: popularWidth, height: popularHeight)
            .background(Color.purchasePopularForegroundShapeColor)
            .cornerRadius(4)
            .offset(.init(width: 0.0, height: popularHeight / -2))
        }
    }
}


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

            OptionItemView(
                title: subscription.displayName,
                description: savings == nil ? nil : subscription.priceText,
                isAvailable: true,
                isSelected: $isOn, rightAccessoryView:  {
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
                }).if(savings != nil, transform: { view in
                view.modifier(MostPopularIndicatorViewModifier())
            })

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


