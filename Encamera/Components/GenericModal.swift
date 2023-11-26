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

    func body(content: Content) -> some View {
        ZStack(alignment: .center) {
            content
            Color.gray.opacity(0.4)
            VStack(spacing: 20) {
                Image(imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                Text(titleText)
                    .fontType(.pt24, on: .lightBackground, weight: .bold)

                VStack(spacing: 40) {
                    VStack(spacing: 0) {
                        Text(descriptionText)
                            .fontType(.pt16, on: .lightBackground, weight: .regular)
                            .frame(alignment: .center)
                            .foregroundColor(Color(red: 0, green: 0, blue: 0))
                            .opacity(0.80)
                            .frame(height: 104)
                    }
                }
                VStack(spacing: 24) {
                    Button(primaryButtonText, action: onPrimaryButtonPressed)
                        .primaryButton()
                    Button(secondaryButtonText, action: onSecondaryButtonPressed)
                        .secondaryButton()
                }
            }
            .padding(EdgeInsets(top: 40, leading: 16, bottom: 24, trailing: 16))
            .background(.white)
            .cornerRadius(8)
        }
    }
}

// Usage
extension View {
    func genericModal(imageName: String, titleText: String, descriptionText: String, primaryButtonText: String, secondaryButtonText: String, onPrimaryButtonPressed: @escaping () -> Void, onSecondaryButtonPressed: @escaping () -> Void) -> some View {
        self.modifier(ModalViewModifier(imageName: imageName, titleText: titleText, descriptionText: descriptionText, primaryButtonText: primaryButtonText, secondaryButtonText: secondaryButtonText, onPrimaryButtonPressed: onPrimaryButtonPressed, onSecondaryButtonPressed: onSecondaryButtonPressed))
    }
}


#Preview {
    VStack {

        Color.orange
            .frame(width: 343, height: 444)
            .genericModal(
                imageName: "Image-Camera",
                titleText: L10n.coolPicture,
                descriptionText: L10n.whereToFindYourPictures,
                primaryButtonText: L10n.viewAlbums,
                secondaryButtonText: L10n.takeAnotherPhoto,
                onPrimaryButtonPressed: { print("Upgrade to Premium") },
                onSecondaryButtonPressed: { print("Back to album") }
            )
    }
}

