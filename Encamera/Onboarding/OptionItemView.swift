//
//  OptionItemView.swift
//  Encamera
//
//  Created by Alexander Freas on 10.10.23.
//

import Foundation
import SwiftUI

private enum Constants {
    static let checkmarkSize = 24.0
    static let checkmarkBorder = 5.0
    static let cornerRadius = 8.0
    static let lineWidth = 1.0
    static let spacing = 4.0
    static let padding = 20.0
    static let opacity = 0.3
    static let offsetMultiplier = 0.5
}


struct OptionItemView: View {

    let title: String
    let description: String
    let isAvailable: Bool
    let unavailableReason: String?
    let image: Image?
    @Binding var isSelected: Bool
    
    init(title: String, description: String, isAvailable: Bool, unavailableReason: String? = nil, image: Image? = nil, isSelected: Binding<Bool>) {
        self.title = title
        self.description = description
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.image = image
        _isSelected = isSelected
    }


    @ViewBuilder private var background: some View {
        let rect = RoundedRectangle(cornerRadius: Constants.cornerRadius, style: .continuous)
        let rectangle = rect
            .stroke(Color.secondaryElementColor, lineWidth: Constants.lineWidth)
        if isSelected {
            rectangle.background(rect.fill(Color.white))
        } else {
            rectangle
        }
    }

    var body: some View {
        let iconWithName = HStack {
            ZStack(alignment: .topTrailing) {
                HStack {
                    VStack(alignment: .leading, spacing: Constants.spacing) {
                        Text(title)
                            .fontType(.pt16, on: isSelected ? .selectedStorageButton : .background, weight: .bold)
                        if let unavailableReason {
                            Text(unavailableReason)
                                .alertText()
                        } else {
                            Text(description)
                                .fontType(.extraSmall, on: isSelected ? .selectedStorageButton : .background)
                        }
                    }
                    Spacer()
                    image?.renderingMode(.template).foregroundColor(isSelected  ? .black : Color.secondaryElementColor)
                }
                .padding(Constants.padding)
                .frame(maxWidth: .infinity)
                .background(background)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .foregroundColor(Color.actionYellowGreen)
                        .background(Circle().foregroundColor(.black).frame(width: Constants.checkmarkSize + Constants.checkmarkBorder, height: Constants.checkmarkSize + Constants.checkmarkBorder))
                        .frame(width: Constants.checkmarkSize, height: Constants.checkmarkSize)
                        .offset(x: Constants.checkmarkSize * Constants.offsetMultiplier, y: -Constants.checkmarkSize * Constants.offsetMultiplier)
                }
            }
        }
        VStack(alignment: .leading) {
            HStack {
                if isAvailable {
                    iconWithName
                } else {
                    iconWithName.opacity(Constants.opacity)
                }
            }
        }
        .onTapGesture {
            isSelected = true
        }
    }
}


struct OptionItemView_Previews: PreviewProvider {
    @State static var selected = false
    @State static var notSelected = false

    static var previews: some View {

        Group {
            OptionItemView(title: "Option 1",
                           description: "This is an available option.",
                           isAvailable: true,
                           image: Image("Onboarding-Permissions-Microphone"),
                           isSelected: $selected)
                .previewLayout(.sizeThatFits)
                .padding()

            OptionItemView(title: "Option 2",
                           description: "This is an available option.",
                           isAvailable: true,
                           image: Image("Onboarding-Permissions-Camera"),
                           isSelected: .constant(true))
                .previewLayout(.sizeThatFits)
                .padding()

            OptionItemView(title: "Option 3",
                           description: "This option is not available.",
                           isAvailable: false,
                           unavailableReason: "Out of Stock",
                           image: nil,
                           isSelected: $notSelected)
                .previewLayout(.sizeThatFits)
                .padding()
        }
        .previewLayout(.sizeThatFits)
        .padding()
        .environment(\.colorScheme, .dark)
    }
}
