//
//  DecryptErrorExplanation.swift
//  Encamera
//
//  Created by Alexander Freas on 17.09.22.
//

import SwiftUI
import EncameraCore

struct DecryptErrorExplanation: View {
    
    var error: MediaViewingError
    
    var body: some View {
        
        VStack(alignment: .leading, spacing: 40) {
            Text(L10n.theMediaYouTriedToOpenCouldNotBeDecrypted)
                .fontType(.medium)
            Group {
                Text(L10n.checkThatTheSameKeyThatWasUsedToEncryptThisMediaIsSetAsTheActiveKey)
                Text(L10n.tapThe) + Text(Image(systemName: "key.fill")) + Text(L10n.iconInTheCameraViewToChangeTheActiveKey)
                Text(error.displayDescription)
            }.fontType(.pt18)
            
        }.padding()
    }
}

struct DecryptErrorExplanation_Previews: PreviewProvider {
    static var previews: some View {
        DecryptErrorExplanation(error: .noKeyAvailable)
    }
}
