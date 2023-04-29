//
//  TutorialCardView.swift
//  Encamera
//
//  Created by Alexander Freas on 29.04.23.
//

import SwiftUI
import EncameraCore

struct TutorialCardView: View {
    
    var title: String
    var tutorialText: String
    var closeButtonPressed: () -> ()
    
    @State private var viewHeight: CGFloat = .infinity
    @State private var opacitySetting: CGFloat = 1.0
    
    var body: some View {
        ZStack(alignment: .leading) {
            
            RoundedRectangle(cornerRadius: 20)
                .foregroundColor(.foregroundSecondary)
            
            VStack(alignment: .leading) {
                Group {
                    Text(title)
                        .fontType(.mediumSmall)
                    Spacer().frame(height: 15)
                    Text(tutorialText)
                        .fontType(.small)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        viewHeight = viewHeight == 1.0 ? .infinity : 1.0
                        opacitySetting = 0.0
                        closeButtonPressed()
                    }
                } label: {
                    Text(L10n.gotIt)
                        .fontType(.extraSmall, on: .elevated)
                }
                .primaryButton(on: .elevated)
            }
            .padding()
            
        }
        .frame(maxHeight: viewHeight)
        .opacity(opacitySetting)
    }
}

struct TutorialCardView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            TutorialCardView(title: "Your Encryption Keys 🔑", tutorialText: "Each key functions as an album, and each album uses a different key to encrypt media.\n\nBackup these keys! If you lose the key or your device, and don't select iCloud backup, your media cannot be recovered.") {
                
            }
            TutorialCardView(title: "Your Encryption Keys 🔑", tutorialText: "Each key functions as an album, and each album uses a different key to encrypt media.\n\nBackup these keys! If you lose the key or your device, and don't select iCloud backup, your media cannot be recovered.") {
                
            }
            Spacer()
        }
            .padding()
            .preferredColorScheme(.dark)
    }
}
