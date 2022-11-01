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
    case small
    
    private var baseFontName: String {
        "Lato-Regular"
    }
    
    var font: Font {
        
        switch self {
        case .large:
            return Font.custom(baseFontName, size: 35)
        case .medium:
            return Font.custom(baseFontName, size: 30)
        case .small:
            return Font.custom(baseFontName, size: 16)
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
    func fontType(_ fontType: EncameraFont) -> some View {
        return self
            .font(fontType.font)
            .foregroundColor(.foregroundPrimary)
    }
}

struct Text_Previews: PreviewProvider {
    
    static var previews: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("This is a large one").fontType(.large)
            Text("This is a medium one").fontType(.medium)
            Text("This is a small one").fontType(.small)
            Text("Alert!").alertText()
        }
        
    }
}
