//
//  Text.swift
//  Encamera
//
//  Created by Alexander Freas on 13.07.22.
//

import Foundation
import SwiftUI

struct TextViewModifier: ViewModifier {

    func body(content: Content) -> some View {
        content
    }
}

enum EncameraFont {
    case large
    case medium
    case pt14
    case pt12
    case pt10
    case pt16
    case pt18
    case pt20
    case pt24
    case pt32
    case rajdhaniBold
    case rajdhaniBoldSmall

    enum Name: String {
        case regular = "Satoshi-Regular"
        case bold = "Satoshi-Bold"
        case rajdhaniBold = "Rajdhani-Bold"
    }
    var offset: CGFloat {
        return 2.0
    }
    var font: Font {

        switch self {
        case .large:
            return satoshi(size: 35)
        case .medium:
            return satoshi(size: 30)
        case .pt32:
            return satoshi(size: 32)
        case .pt24:
            return satoshi(size: 24)
        case .pt20:
            return satoshi(size: 20)
        case .pt18:
            return satoshi(size: 18)
        case .pt16:
            return satoshi(size: 16)
        case .pt14:
            return satoshi(size: 14)
        case .pt12:
            return satoshi(size: 12)

        case .pt10:
            return satoshi(size: 10)
        case .rajdhaniBold:
            return .custom(Name.rajdhaniBold.rawValue, size: 16)
        case .rajdhaniBoldSmall:
            return .custom(Name.rajdhaniBold.rawValue, size: 12)

        }
    }

    private func satoshi(size: CGFloat) -> Font {
        return .custom(Name.regular.rawValue, size: size + offset)
    }
}

extension Text {


    func alertText() -> some View {
        return self
            .foregroundColor(.alertTextColor)
            .fontType(.pt14, weight: .bold)
            .lineLimit(3)
            .padding(10)
            .cornerRadius(10)
    }
}

extension View {
    func fontType(_ fontType: EncameraFont, on surface: SurfaceType = .background, weight: Font.Weight = .regular) -> some View {
        return self
            .font(fontType.font.weight(weight))
            .foregroundColor(surface.textColor)
    }
}

struct Text_Previews: PreviewProvider {

    static var previews: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("This is a large one").fontType(.large)
            Text("This is a medium one").fontType(.medium)

            Text("This is a small one").fontType(.pt18)
            Text("This is a small one").fontType(.pt14)
            Text("Rajdhani-Bold").fontType(.rajdhaniBold)

            Text("Alert!").alertText()
        }

    }
}
