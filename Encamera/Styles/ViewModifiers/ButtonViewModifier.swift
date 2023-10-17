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

extension View {
    //TODO: Remove references to surface, we don't need it
    func primaryButton(on surface: SurfaceType = .background) -> some View {
        buttonStyle(EncameraButtonStyle(hostSurface: .primaryButton))
    }
    
    func destructiveButton(on surface: SurfaceType = .background) -> some View {
        buttonStyle(EncameraDestructiveButtonStyle(hostSurface: surface))
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
                    
                }.primaryButton(on: .background)

            }
            ZStack {
                Color.foregroundSecondary.frame(width: 100, height: 100  )
                Button("Share") {
                    
                }.primaryButton(on: .elevated)
            }
            ZStack {
                Color.foregroundSecondary.frame(width: 100, height: 100  )
                Button("Destroy") {
                    
                }.destructiveButton(on: .elevated)
            }
        }
        .frame(maxWidth: .infinity)
        .preferredColorScheme(.dark)
    }
}
