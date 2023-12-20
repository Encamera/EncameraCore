//
//  OptionItemViewModifier.swift
//  Encamera
//
//  Created by Alexander Freas on 03.12.23.
//

import Foundation
import SwiftUI

private enum Constants {
    static let checkmarkSize = 24.0
    static let checkmarkBorder = 5.0
    static let offsetMultiplier = 0.5
    static let cornerRadius = 8.0
    static let lineWidth = 1.0
    static let opacity = 0.3

}

struct OptionItemViewModifier: ViewModifier {

    var isSelected: Bool
    var isAvailable: Bool
    
    @ViewBuilder private var background: some View {
        let rect = RoundedRectangle(cornerRadius: Constants.cornerRadius, style: .continuous)
        let rectangle = rect
            .stroke(Color.secondaryElementColor, lineWidth: Constants.lineWidth)
        if isSelected {
            rectangle.background(rect.fill(Color.white))
        } else {
            rectangle.background(rect.fill(Color.black))
        }
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .topTrailing) {

            content
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
        .if(isAvailable == false, transform: { v in
            v.opacity(Constants.opacity)
        })
    }
}

extension View {
    func optionItem(isSelected: Bool, isAvailable: Bool) -> some View {
        self.modifier(OptionItemViewModifier(isSelected: isSelected, isAvailable: isAvailable))
    }
}
