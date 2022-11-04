//
//  FirstPhotoTaken.swift
//  Encamera
//
//  Created by Alexander Freas on 02.11.22.
//

import SwiftUI

struct FirstPhotoTakenTutorial: View, TutorialView {
    
    @Binding var shouldShow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text("Congratulations!")
                .fontType(.large)
            Group {
                Text("You took your first photo! 📸 🥳")
                Text("See the photos that belong to a key by tapping the \(Image(systemName: "key.fill")) icon on the top left of the screen.")
            }.fontType(.mediumSmall)
            HStack {
                Button("Got it!") {
                    withAnimation {
                        shouldShow = false
                    }
                    
                }.primaryButton(on: .elevated)
            }
        }
        .padding()
        .background(Color.foregroundSecondary)
        .cornerRadius(AppConstants.defaultCornerRadius)

        
    }
}

struct FirstPhotoTakenTutorial_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.background
            
                FirstPhotoTakenTutorial(shouldShow: .constant(true))
            
        }.preferredColorScheme(.dark)
        
    }
}
