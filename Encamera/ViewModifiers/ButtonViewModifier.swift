//
//  ButtonViewModifier.swift
//  Encamera
//
//  Created by Alexander Freas on 16.11.21.
//

import Foundation
import SwiftUI


struct EncameraButtonStyle: ButtonStyle {
    
    var hostSurface: SurfaceType

    func makeBody(configuration: Configuration) -> some View {
        return configuration.label
            .fontType(.pt18, on: hostSurface, weight: .bold)
            .padding(12.0)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(hostSurface.foregroundSecondary)
            .cornerRadius(10)
    }
}

struct EncameraDestructiveButtonStyle: ButtonStyle {
    
    var hostSurface: SurfaceType

    
    func makeBody(configuration: Configuration) -> some View {
        return configuration.label
            .fontType(.pt18, on: hostSurface)
            .padding(12.0)
            .foregroundColor(.red)
            .frame(minHeight: 44)
            .background(.red)
            .cornerRadius(10)
    }
}

struct FrostedBackgroundButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding([.leading, .trailing])
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial) // Background color and transparency
                    .frame(height: 36) // Size of the circular button
                    .cornerRadius(44)
            }

    }
}

extension View {
    //TODO: Remove references to surface, we don't need it
    func primaryButton(enabled: Bool = true) -> some View {
        buttonStyle(EncameraButtonStyle(hostSurface: enabled ? .primaryButton : .disabledButton))
    }

    func destructiveButton(on surface: SurfaceType = .background) -> some View {
        buttonStyle(EncameraDestructiveButtonStyle(hostSurface: surface))
    }
    
    func secondaryButton(enabled: Bool = true) -> some View {
        buttonStyle(EncameraButtonStyle(hostSurface: .secondaryButton))
    }

    func textButton() -> some View {
        self.padding(12.0)
        .fontType(.pt14, on: .textButton, weight: .bold)
    }

    func frostedButton() -> some View {
        self
            .modifier(FrostedBackgroundButtonStyle())
    }
}

struct EncameraButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading) {
            Button("Encrypt Everything") {
                
            }.primaryButton()
            ZStack {
                Color.background.frame(width: 100, height: 100  )
                Button("Unlock") {
                    
                }.primaryButton()

            }
            ZStack {
                Color.actionYellowGreen.frame(width: 100, height: 100  )
                Button("Share") {
                    
                }.primaryButton()
            }
            ZStack {
                Color.white.frame(width: 100, height: 100  )
                Button("Destroy") {
                    
                }.destructiveButton(on: .darkBackground)
            }
            ZStack {
                Color.white.frame(width: 100, height: 100  )
                Button("Destroy") {

                }.frostedButton()
            }

        }
        .frame(maxWidth: .infinity)
        .preferredColorScheme(.dark)
    }
}
