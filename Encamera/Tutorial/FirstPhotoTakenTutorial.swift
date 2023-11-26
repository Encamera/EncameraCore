//
//  FirstPhotoTaken.swift
//  Encamera
//
//  Created by Alexander Freas on 02.11.22.
//

import SwiftUI
import EncameraCore

struct FirstPhotoTakenTutorial: View, TutorialView {
    
    @Binding var shouldShow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(L10n.congratulations)
                .fontType(.large)
            Group {
                Text(L10n.youTookYourFirstPhoto📸🥳)
                Text(L10n.seeThePhotosThatBelongToAKeyByTappingThe) + Text(Image(systemName: "key.fill")) + Text(L10n.iconOnTheTopLeftOfTheScreen)
            }.fontType(.pt24)
            HStack {
                Button(L10n.gotIt) {
                    withAnimation {
                        shouldShow = false
                    }
                    
                }.primaryButton(on: .darkBackground)
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
