//
//  BuyButtonStyle.swift
//  Encamera
//
//  Created by Alexander Freas on 26.10.22.
//

import Foundation
import SwiftUI

struct BuyButtonStyle: ButtonStyle {
    let isPurchased: Bool

    init(isPurchased: Bool = false) {
        self.isPurchased = isPurchased
    }

    func makeBody(configuration: Self.Configuration) -> some View {
        let interactable = isPurchased == false && configuration.isPressed
        var bgColor: Color = isPurchased ? Color.green : Color.foregroundPrimary
        bgColor = configuration.isPressed ? bgColor.opacity(0.7) : bgColor.opacity(1)

        return configuration.label
            .fontType(.small, on: .elevated)
            .padding(10)
            .background(bgColor)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .scaleEffect(interactable ? 0.9 : 1.0)
    }
}
