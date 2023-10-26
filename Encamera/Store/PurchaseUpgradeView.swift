//
//  SubscriptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import SwiftUI
import StoreKit
import EncameraCore

typealias ProductStoreView = PurchaseUpgradeView

struct FeatureIcon: View {
    let image: Image

    var body: some View {
        ZStack {
            Rectangle()
                .foregroundColor(.clear)
                .frame(width: 42, height: 42)
                .background(Color.white)
                .cornerRadius(4)
                .opacity(0.10)
            image
                .opacity(0.50)
        }
        .frame(width: 42, height: 42)
    }
}

struct FeatureText: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: subtitle != nil ? 4 : nil) {
            Group {
                Text(title)
                    .fontType(.pt14, weight: .bold)
                    .foregroundColor(.white)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(Font.custom("Satoshi Variable", size: 14))
                        .foregroundColor(.white)
                        .opacity(0.80)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            
        }.frame(height: 50)
    }
}

func createFeatureRow(image: Image, title: String, subtitle: String? = nil) -> some View {
    return HStack(alignment: .center, spacing: 12) {
        FeatureIcon(image: image)
        FeatureText(title: title, subtitle: subtitle)
    }
}

struct PurchaseUpgradeView: View {
    @ObservedObject var subscriptionController: StoreSubscriptionController = StoreActor.shared.subscriptionController
    @ObservedObject var productController: StoreProductController = StoreActor.shared.productController
    @State private var selectedSubscription: ServiceSubscription?
    @State private var currentActiveSubscription: ServiceSubscription?
    @State private var errorAlertIsPresented = false
    @State private var showTweetForFreeView = false
    var showDismissButton = true
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 8) {
            PurchaseUpgradeHeaderView()
                .frame(maxWidth: .infinity)
            createFeatureRow(image: Image("Premium-Infinity"), title: "Unlimited Albums")
            createFeatureRow(image: Image("Premium-Albums"), title: "Unlimited Photos")
            createFeatureRow(image: Image("Premium-Folders"), title: "Password Protected Albums")
            createFeatureRow(image: Image("Premium-CustomIcon"), title: "Custom Icon")
            productCellsScrollView
        }
        .padding()
        .navigationBarTitle(L10n.upgradeToday)
        .overlay(alignment: .topTrailing) {
            if showDismissButton {
                dismissButton
                    .padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectedSubscription != nil {
                subscriptionPurchaseView
            }
        }
        .background(Color.background)
        .onAppear {
            selectedSubscription = subscriptionController.entitledSubscription
            currentActiveSubscription = subscriptionController.entitledSubscription
        }
        .alert(
            subscriptionController.purchaseError?.errorDescription ?? "",
            isPresented: $errorAlertIsPresented,
            actions: {}
        )
        .sheet(isPresented: $showTweetForFreeView) {
            TweetToShareView()
        }
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
                    let action = await subscriptionController.purchase(option: subscription)
                    switch action {
                    case .dismissStore: dismiss()
                    case .displayError: errorAlertIsPresented = true
                    case .noAction: break
                    }
                }
            }
        }
    }
    
    var productCellsScrollView: some View {
        ScrollView(.vertical) {

        }.padding()
    }
}


struct SubscriptionPurchaseButton: View {
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
                        Text(L10n.startTrialOffer)
                    } else {
                        Text(L10n.subscribe)
                    }
                }
                .padding(5)
                .frame(maxWidth: .infinity)
            }
            
            .primaryButton(on: .darkBackground)
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
                canRedeemIntroOffer = await selectedSubscription.isEligibleForIntroOffer && selectedSubscription.introductoryOffer != nil
            }
        }
    }

}

struct PurchaseUpgradeView_Previews: PreviewProvider {
    
    static var previews: some View {
        ProductStoreView()
            .preferredColorScheme(.dark)
            .previewDevice(PreviewDevice(rawValue: "iPhone 8"))
    }
    
}
