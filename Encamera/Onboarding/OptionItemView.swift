//
//  OptionItemView.swift
//  Encamera
//
//  Created by Alexander Freas on 10.10.23.
//

import Foundation
import SwiftUI

private enum Constants {
    static let spacing = 4.0
    static let padding = 20.0
}

struct OptionItemView<Content: View>: View {

    let title: String
    let rightAccessoryView: (() -> Content)?
    let description: String?
    let isAvailable: Bool
    let unavailableReason: String? = nil
    let image: Image?
    let tappedAction: (() -> Void)?
    @Binding var isSelected: Bool


    init(title: String, 
         description: String?,
         isAvailable: Bool,
         unavailableReason: String? = nil,
         image: Image? = nil,
         isSelected: Binding<Bool>,
         rightAccessoryView: (() -> Content)? = { EmptyView() },
         tappedAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.rightAccessoryView = rightAccessoryView
        self.description = description
        self.isAvailable = isAvailable
        self.image = image
        self.tappedAction = tappedAction
        _isSelected = isSelected
    }


    var body: some View {
        let iconWithName = HStack {
            HStack {
                VStack(alignment: .leading, spacing: Constants.spacing) {
                    Text(title)
                        .fontType(.pt16, on: isSelected ? .selectedStorageButton : .background, weight: .bold)
                    if let unavailableReason {
                        Text(unavailableReason)
                            .alertText()
                    } else if let description {
                        Text(description)
                            .fontType(.pt14, on: isSelected ? .selectedStorageButton : .background)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                if let image {
                    image.renderingMode(.template).foregroundColor(isSelected  ? .black : Color.secondaryElementColor)
                } else if let rightAccessoryView {
                    rightAccessoryView()
                }
            }
            .padding(Constants.padding)
            .frame(maxWidth: .infinity)

        }
        .optionItem(isSelected: isSelected, isAvailable: isAvailable)

        Button(action: {
            tappedAction?()
            isSelected = true
        }, label: {
            VStack(alignment: .leading) {
                HStack {
                    iconWithName
                }
            }
        })
    }
}


struct OptionItemView_Previews: PreviewProvider {
    @State static var selected = false
    @State static var notSelected = false

    static var previews: some View {

        VStack(spacing: 30) {
            OptionItemView(title: "Option 1",
                           description: "This is an available option with a lot of text that should be leading aligned.",
                           isAvailable: true,
                           image: Image("Onboarding-Permissions-Microphone"),
                           isSelected: $selected)

            OptionItemView(title: "Option 2",
                           description: "This is an available option.",
                           isAvailable: true,
                           image: Image("Onboarding-Permissions-Camera"),
                           isSelected: .constant(true))

            OptionItemView(title: "Option 3",
                           description: "This option is not available.",
                           isAvailable: false,
                           unavailableReason: "Out of Stock",
                           image: nil,
                           isSelected: $notSelected)


            OptionItemView(title: "Option 4",
                           description: "12 Months - $107",
                           isAvailable: true,
                           isSelected: .constant(false)) {
                VStack {
                    Text("$8.99 / Mo")
                        .fontType(.pt14, weight: .bold)
                    Text("Save $100")
                        .fontType(.pt10, on: .lightBackground, weight: .bold)
                        .textPill(color: .white)
                }
            }
        }
        .previewLayout(.sizeThatFits)
        .padding()
        .environment(\.colorScheme, .dark)
    }
}
