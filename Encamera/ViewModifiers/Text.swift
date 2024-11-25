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
    case pt10, pt12, pt14, pt16, pt18, pt20, pt24, pt32
    case rajdhaniBold, rajdhaniBoldSmall

    enum Name: String {
        case regular = "Satoshi-Regular"
        case bold = "Satoshi-Bold"
        case rajdhaniBold = "Rajdhani-Bold"
    }

    var offset: CGFloat {
        return 2.0
    }

    var fontSize: CGFloat {
        switch self {
        case .large: return 35
        case .medium: return 30
        case .pt10: return 10
        case .pt12: return 12
        case .pt14: return 14
        case .pt16: return 16
        case .pt18: return 18
        case .pt20: return 20
        case .pt24: return 24
        case .pt32: return 32
        case .rajdhaniBold: return 16
        case .rajdhaniBoldSmall: return 12
        }
    }

    var fontName: String {
        switch self {
        case .rajdhaniBold, .rajdhaniBoldSmall:
            return Name.rajdhaniBold.rawValue
        default:
            return Name.regular.rawValue
        }
    }

    var font: Font {
        return .custom(fontName, size: fontSize + (isSatoshi ? offset : 0))
    }

    var uiFont: UIFont {
        return UIFont(name: fontName, size: fontSize + (isSatoshi ? offset : 0)) ?? UIFont.systemFont(ofSize: fontSize)
    }

    private var isSatoshi: Bool {
        return fontName == Name.regular.rawValue
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
