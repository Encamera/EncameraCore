//
//  KeyInformation.swift
//  Encamera
//
//  Created by Alexander Freas on 13.09.22.
//

import SwiftUI
import EncameraCore

struct KeyInformation: View {
    
    @State var key: PrivateKey
    @Binding var keyManagerError: KeyManagerError?
    
    var body: some View {
        
                Group {
                    Text("\(key.name)")
                        .fontType(.large)
                    
                    
                    Text("\(key.keyString)")
                    
                    Text(L10n.created(DateUtils.dateOnlyString(from: key.creationDate)))
                        .fontType(.pt18)
                    Text(L10n.keyLength(key.keyBytes.count))
                }.listRowBackground(Color.foregroundSecondary)
    }
}

struct KeyInformation_Previews: PreviewProvider {
    static var previews: some View {
        KeyInformation(key: DemoPrivateKey.dummyKey(), keyManagerError: .constant(KeyManagerError.dataError))
            .preferredColorScheme(.dark)
    }
}
