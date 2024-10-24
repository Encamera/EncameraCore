//
//  PurchaseUpgradeHeaderView.swift
//  Encamera
//
//  Created by Alexander Freas on 23.11.22.
//

import SwiftUI
import EncameraCore
import CoreMotion

// Custom view modifier for tilt effect
struct TiltEffectModifier: ViewModifier {
    @State private var motionManager = CMMotionManager()
    @State private var tiltAngle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(Angle(degrees: tiltAngle), axis: (x: 0, y: 1, z: 0))
            .onAppear {
                startTiltEffect()
            }
    }

    private func startTiltEffect() {
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 0.01
            motionManager.startAccelerometerUpdates(to: .main) { data, _ in
                guard let data = data else { return }
                // Adjust tilt angle based on accelerometer data
                tiltAngle = -data.acceleration.x * 5 // Adjust multiplier for sensitivity
            }
        }
    }
}

struct PurchaseUpgradeHeaderView: View {
    @State private var isAppearing = false
    var isInPromoMode: Bool = true
    var purchasedProduct: OneTimePurchase?
    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            Spacer()
            Image(AppConstants.isInPromoMode ? "Pumpkin" : "Premium-Lock")
            Group {
                if (purchasedProduct != nil) {
                    Text(L10n.thanksForPurchasingLifetime)
                        .fontType(.pt24, on: .darkBackground, weight: .bold)
                    Text(L10n.thanksForPurchasingLifetimeSubtitle)
                        .fontType(.pt14)
                } else {
                    Text(AppConstants.isInPromoMode ? L10n.getPremiumPromoText : L10n.getPremium)
                        .fontType(.pt24, on: .darkBackground, weight: .bold)
                    Text(AppConstants.isInPromoMode ? L10n.promoPremiumUnlockTheseBenefits : L10n.premiumUnlockTheseBenefits)
                        .fontType(.pt14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
        }
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .frame(height: 285)

        .background {
            GeometryReader { geo in
                let frame = geo.frame(in: .local)
                ZStack {
                    let offsetX: CGFloat = 100 * (isAppearing ? 1 : 0)
                    let offsetY: CGFloat = 60 * (isAppearing ? 1 : 0)
                    let foregroundImageXOffset = offsetX * 0.7
                    let foregroundImageYOffset = offsetY *  2.0
                    Group {
                        Image("Premium-London")
                            .position(frame.offsetBy(dx: offsetX, dy: offsetY).origin)
                            .opacity(AppConstants.isInPromoMode ? 0 : 1)
                        Image("Premium-Couple")
                            .position(frame.offsetBy(dx: frame.width - offsetX, dy: offsetY).origin)
                            .opacity(AppConstants.isInPromoMode ? 0 : 1)
                        Image(AppConstants.isInPromoMode ? "CandyBlur1" : "Premium-Fitness")
                            .position(frame.offsetBy(dx: foregroundImageXOffset, dy: foregroundImageYOffset).origin)
                        Image(AppConstants.isInPromoMode ? "CandyBlur" : "Premium-Bachelor")
                            .position(frame.offsetBy(dx: frame.width - foregroundImageXOffset, dy: foregroundImageYOffset).origin)
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5)) {
                isAppearing = true
            }
        }
    }
}


struct PurchaseUpgradeHeaderView_Previews: PreviewProvider {
    static var previews: some View {
        PurchaseUpgradeHeaderView()


    }
}
