//
//  SubscriptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import SwiftUI



struct SubscriptionStoreView: View {
    @ObservedObject var controller: StoreSubscriptionController
    @State private var selectedSubscription: ServiceSubscription?
    @State private var errorAlertIsPresented = false
    var showDismissButton = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Group {
            GeometryReader { proxy in
                if proxy.size.height > proxy.size.width {
                    VStack(spacing: 0) {
                        SubscriptionStoreHeaderView()
                            .frame(maxWidth: .infinity)
                        subscriptionCellsView
                    }
                    .safeAreaInset(edge: .bottom) {
                        subscriptionPurchaseView
                    }
                    
                    .overlay(alignment: .topTrailing) {
                        if showDismissButton {
                            dismissButton
                                .padding()
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        SubscriptionStoreHeaderView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider().ignoresSafeArea()
                        VStack {
                            subscriptionCellsView
                                .padding(.top, 30)
                                .frame(width: 400)
                                .ignoresSafeArea()
                            subscriptionPurchaseView
                                .padding(.horizontal, 30)
                        }
                    }
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        dismissButton
                            .padding(.top, 8)
                    }
                }
            }
            
        }
        .background(Color.background)
        .onAppear {
            selectedSubscription = controller.entitledSubscription
        }
        .alert(
            controller.purchaseError?.errorDescription ?? "",
            isPresented: $errorAlertIsPresented,
            actions: {}
        )
    }
    
    var dismissButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    .secondary,
                    .clear,
                    Color(uiColor: .systemGray5)
                )
        }
        .buttonStyle(.borderless)
        .opacity(0.8)
        .font(.title)
    }
    
    var subscriptionPurchaseView: some View {
        SubscriptionPurchaseView(selectedSubscription: selectedSubscription) {
            if let subscription = selectedSubscription {
                Task(priority: .userInitiated) { @MainActor in
                    let action = await controller.purchase(option: subscription)
                    switch action {
                    case .dismissStore: dismiss()
                    case .displayError: errorAlertIsPresented = true
                    case .noAction: break
                    }
                }
            }
        }
    }
    
    var subscriptionCellsView: some View {
        ScrollView(.vertical) {
            if let subscriptions = controller.subscriptions {
                SubscriptionStoreOptionsView(
                    subscriptions: subscriptions,
                    selectedOption: $selectedSubscription
                )
                .padding(.top)
            }
        }
    }
}
     
struct SubscriptionStoreHeaderView: View {
    
    var body: some View {
        VStack {
            Text("Encamera Premium")
                .font(.largeTitle)
                .bold()
                .padding()
            Group {
                Text("Unlimited privacy features.")
            }
            .font(.headline)
        }
        .padding(.top, 5)
        .padding(.bottom, 30)
        .foregroundColor(.white)
    }
    
}

struct SubscriptionStoreOptionsView: View {
    let subscriptions: [ServiceSubscription]
    @Binding var selectedOption: ServiceSubscription?
    
    func binding(for subscription: ServiceSubscription) -> Binding<Bool> {
        print("selected option", selectedOption?.id)
        return Binding {
            selectedOption?.id == subscription.id
        } set: { newValue in
            selectedOption = newValue ? subscription : nil
        }
    }
    
    var body: some View {
        VStack {
            ForEach(subscriptions) { subscription in
                subscriptionOptionCell(for: subscription)
            }
        }
    }

    func subscriptionOptionCell(for subscription: ServiceSubscription) -> some View {
        var savingsInfo: SubscriptionSavings?
        if subscription.id == StoreActor.unlimitedYearlyID {
            savingsInfo = self.savings()
        }
        return SubscriptionOptionView(
            subscription: subscription,
            savings: savingsInfo,
            isOn: binding(for: subscription)
        )
    }
    
    func savings() -> SubscriptionSavings? {
        guard let yearlySubscription = subscriptions.first(where: { $0.id == StoreActor.unlimitedYearlyID }) else {
            return nil
        }
        guard let monthlySubscription = subscriptions.first(where: { $0.id == StoreActor.unlimitedMonthlyID }) else {
            return nil
        }
        
        let yearlyPriceForMonthlySubscription = 12 * monthlySubscription.price
        let amountSaved = yearlyPriceForMonthlySubscription - yearlySubscription.price
        
        guard amountSaved > 0 else {
            return nil
        }
        
        let percentSaved = amountSaved / yearlyPriceForMonthlySubscription
        let monthlyPrice = yearlySubscription.price / 12
        
        return SubscriptionSavings(percentSavings: percentSaved, granularPrice: monthlyPrice, granularPricePeriod: .month)
    }
}

struct SubscriptionOptionView: View {
    let subscription: ServiceSubscription
    let savings: SubscriptionSavings?

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
                 Text(subscription.displayName)
                    .font(.headline)
                 Text(subscription.description)
                     .padding(.bottom, 2)
                 Text(applyKerning(to: "/", in: subscription.priceText))
                 if let savingsText = savingsText {
                     Text(applyKerning(to: "/()", in: savingsText))
                         .foregroundColor(.accentColor)
                 }
            }
            Spacer()
            checkmarkImage
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Self.backgroundColor, in: Self.backgroundShape)
        .overlay {
            Self.backgroundShape
                .strokeBorder(
                    Color.accentColor,
                    lineWidth: isOn ? 1 : 0
                )
        }
        .onTapGesture {
            isOn.toggle()
        }
        .padding(.horizontal)
        .padding(.vertical, 5)
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

struct SubscriptionPurchaseView: View {
    @State private var canRedeemIntroOffer = false
    @State private var redeemSheetIsPresented = false
    
    @Environment(\.dismiss) private var dismiss
    
    let selectedSubscription: ServiceSubscription?
    let onPurchase: () -> Void
    
    var body: some View {
        VStack {
            Button {
                onPurchase()
            } label: {
                Group {
                    if canRedeemIntroOffer {
                        Text("Start trial offer")
                    } else {
                        Text("Subscribe")
                    }
                }
                .padding(5)
                .frame(maxWidth: .infinity)
            }
            .primaryButton()
            .disabled(selectedSubscription == nil)
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
        .onChange(of: selectedSubscription) { newValue in
            guard let selectedSubscription = newValue?.subscriptionInfo else {
                return
            }
            Task(priority: .utility) { @MainActor in
                canRedeemIntroOffer = await selectedSubscription.isEligibleForIntroOffer
            }
        }
    }

}

struct SubscriptionStoreView_Previews: PreviewProvider {
    
    static var previews: some View {
        SubscriptionStoreView(
            controller: StoreActor.shared.subscriptionController
        ).preferredColorScheme(.dark)
    }
    
}
