//
//  DecryptErrorExplanation.swift
//  Encamera
//
//  Created by Alexander Freas on 17.09.22.
//

import SwiftUI

struct DecryptErrorExplanation: View {
    
    var error: MediaViewingError
    
    var body: some View {
        
        VStack(alignment: .leading, spacing: 40) {
            Text("The media you tried to open could not be decrypted.")
                .font(.headline)
            
            Text("Check that the same key that was used to encrypt this media is set as the active key.")
                    Text("Tap the ") + Text(Image(systemName: "key.fill")) + Text(" icon in the camera view to change the active key.")
            Text(error.displayDescription)
            
        }.padding()
    }
}

struct DecryptErrorExplanation_Previews: PreviewProvider {
    static var previews: some View {
        DecryptErrorExplanation(error: .noKeyAvailable)
    }
}
