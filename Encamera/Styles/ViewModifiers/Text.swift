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

    enum Name: String {
        case regular = "Satoshi-Regular"
        case bold = "Satoshi-Bold"
    }

    var font: Font {

        switch self {
        case .large:
            return .custom(Name.regular.rawValue, size: 35)
        case .medium:
            return .custom(Name.regular.rawValue, size: 30)
        case .pt20:
            return .custom(Name.regular.rawValue, size: 20)
        case .pt24:
            return .custom(Name.regular.rawValue, size: 24)
        case .pt18:
            return .custom(Name.regular.rawValue, size: 18)
        case .pt16:
            return .custom(Name.regular.rawValue, size: 16)

        case .pt14:
            return .custom(Name.regular.rawValue, size: 14)
        case .pt12:
            return .custom(Name.regular.rawValue, size: 12)

        case .pt10:
            return .custom(Name.regular.rawValue, size: 10)
        }
    }
}

extension Text {
    
    
    func alertText() -> some View {
        return self
            .fontType(.pt18)
            .lineLimit(3)
            .padding(10)
                        .background(Color.red)
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

            Text("Alert!").alertText()
        }
        
    }
}
