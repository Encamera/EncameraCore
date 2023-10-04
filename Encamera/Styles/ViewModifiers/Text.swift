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
    case mediumSmall
    case small
    case extraSmall

    enum Name: String {
        case regular = "Satoshi-Regular"
        case bold = "Satoshi-Bold"
    }

    var font: Font {
        
        switch self {
        case .large:
            return Font.custom(Name.regular.rawValue, size: 35)
        case .medium:
            return Font.custom(Name.regular.rawValue, size: 30)
        case .mediumSmall:
            return Font.custom(Name.regular.rawValue, size: 24)
        case .small:
            return Font.custom(Name.regular.rawValue, size: 18)
        case .extraSmall:
            return Font.custom(Name.regular.rawValue, size: 16)
        }
    }
}

extension Text {
    
    
    func alertText() -> some View {
        return self
            .fontType(.small)
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
            Text("This is a medium small one").fontType(.mediumSmall)

            Text("This is a small one").fontType(.small)
            Text("This is a small one").fontType(.extraSmall)

            Text("Alert!").alertText()
        }
        
    }
}
