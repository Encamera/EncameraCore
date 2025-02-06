//
//  ScreenBlocking.swift
//  Encamera
//
//  Created by Alexander Freas on 29.08.22.
//

import Foundation
import SwiftUI

struct ScreenBlockingModifier: ViewModifier {
    
    @Environment(\.isScreenBlockingActive) var isScreenBlockingActive
    
    func body(content: Content) -> some View {
        ZStack {
            
            content
            if isScreenBlockingActive {
                Color.clear.edgesIgnoringSafeArea(.all)
                    .gradientBackground()
            }
        }
        
    }
}

extension View {
    
    func screenBlocked() -> some View {
        return modifier(ScreenBlockingModifier())
    }
}
