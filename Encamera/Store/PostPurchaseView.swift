//
//  PostPurchaseView.swift
//  Encamera
//
//  Created by Alexander Freas on 22.04.24.
//

import SwiftUI
import EncameraCore

struct PostPurchaseView: View {

    
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack {
            Spacer().frame(height: 100)
            Image("PostPurchaseView-ThumbsUp")
            

            VStack(spacing: 34) {
                Text(L10n.PostPurchaseView.thanksForYourPurchase).fontType(.pt24, weight: .bold)
                Text(L10n.PostPurchaseView.subtext1).fontType(.pt16, weight: .thin)
                Text(L10n.PostPurchaseView.subtext2).fontType(.pt16)
            }
            .frame(width: 320)
            .multilineTextAlignment(.center)
            Spacer()
            DualButtonComponent(nextActive: .constant(false), bottomButtonTitle: L10n.PostPurchaseView.reviewButton, bottomButtonAction: {
                AskForReviewUtil.openAppStoreReview()
            }, secondaryButtonTitle: L10n.PostPurchaseView.maybeLater, secondaryButtonAction: {
                dismiss()
            })
        }
        .overlay(alignment: .topLeading) {
            dismissButton
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gradientBackground()

    }

    var dismissButton: some View {
        DismissButton {
            dismiss()
        }
    }

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }
}

#Preview {
    PostPurchaseView()
}
