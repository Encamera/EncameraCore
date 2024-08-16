//
//  GenericModal.swift
//  Encamera
//
//  Created by Alexander Freas on 26.11.23.
//

import SwiftUI
import EncameraCore

struct ModalViewModifier: ViewModifier {
    let imageName: String
    let titleText: String
    let descriptionText: String
    let primaryButtonText: String
    let secondaryButtonText: String
    let onPrimaryButtonPressed: () -> Void
    let onSecondaryButtonPressed: () -> Void
    var animated: Bool = false  // Added animated property with default value
    var addOverlay: Bool = true

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content
            if addOverlay {
                Color.clear.background(.ultraThinMaterial)
            }
            VStack(alignment: .center, spacing: 0) {
                Spacer().frame(height: 40)
                Image(imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                Spacer().frame(height: 40)
                Text(titleText)
                    .fontType(.pt24, on: .lightBackground, weight: .bold)
                Spacer().frame(height: 16)

                Text(descriptionText)
                    .fontType(.pt16, on: .lightBackground, weight: .regular)
                    .frame(alignment: .center)
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color(red: 0, green: 0, blue: 0))
                    .opacity(0.80)
                Spacer().frame(height: 48)

                VStack(spacing: 24) {
                    Button(primaryButtonText, action: onPrimaryButtonPressed)
                        .primaryButton()
                    Button(secondaryButtonText, action: onSecondaryButtonPressed)
                        .secondaryButton()
                }
                .padding()
            }
            .background(.white)
            .cornerRadius(8)
            .padding(EdgeInsets(top: 40, leading: 16, bottom: 24, trailing: 16))
            .animation(animated ? .default : nil, value: animated)
            .transition(.opacity)
        }.edgesIgnoringSafeArea(.all)
    }
}

// Usage
extension View {
    @ViewBuilder
    func genericModal(isPresented: Binding<Bool>, imageName: String, titleText: String, descriptionText: String, primaryButtonText: String, secondaryButtonText: String, onPrimaryButtonPressed: @escaping () -> Void, onSecondaryButtonPressed: @escaping () -> Void, animated: Bool = false, addOverlay: Bool = true) -> some View {
        if isPresented.wrappedValue {
            self.modifier(ModalViewModifier(imageName: imageName, titleText: titleText, descriptionText: descriptionText, primaryButtonText: primaryButtonText, secondaryButtonText: secondaryButtonText, onPrimaryButtonPressed: onPrimaryButtonPressed, onSecondaryButtonPressed: onSecondaryButtonPressed, animated: animated, addOverlay: addOverlay))
        } else {
            self
        }
    }
}


#Preview {
    VStack {

        Color.orange
            .frame(width: 343, height: 444)
            .genericModal(
                isPresented: .constant(true),
                imageName: "Image-Camera",
                titleText: L10n.coolPicture,
                descriptionText: L10n.whereToFindYourPictures,
                primaryButtonText: L10n.viewAlbums,
                secondaryButtonText: L10n.takeAnotherPhoto,
                onPrimaryButtonPressed: { print("Upgrade to Premium") },
                onSecondaryButtonPressed: { print("Back to album") },
                animated: true  // Set to true to enable animation
            )
    }
}
