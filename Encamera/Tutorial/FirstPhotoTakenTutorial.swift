//
//  FirstPhotoTaken.swift
//  Encamera
//
//  Created by Alexander Freas on 02.11.22.
//

import SwiftUI

struct FirstPhotoTakenTutorial: View {
    
    
    @Binding var shouldShow: Bool
    
    init(shouldShow: Binding<Bool>) {
        _shouldShow = shouldShow
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Constants.spacing) {
            Text("Congratulations!")
                .fontType(.large)
            Group {
                Text("You took your first photo! 📸 🥳")
                Text("See the photos for a key by tapping the \(Image(systemName: "key.fill")) icon on the top left of the screen.")
            }
            .fontType(.mediumSmall)
            Button("Got it!") {
                withAnimation {
                    shouldShow = false
                }
                
            }.primaryButton(on: .elevated)
        }
        .padding()
        .background(Color.foregroundSecondary)
        .cornerRadius(AppConstants.defaultCornerRadius)
    }
    
    private enum Constants {
        static var spacing = 25.0
    }
}

struct FirstPhotoTakenTutorial_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.background
            FirstPhotoTakenTutorial(shouldShow: .constant(true)).background(Color.clear)
        }.preferredColorScheme(.dark)
        
    }
}
