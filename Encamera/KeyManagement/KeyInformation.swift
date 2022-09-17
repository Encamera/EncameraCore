//
//  KeyInformation.swift
//  Encamera
//
//  Created by Alexander Freas on 13.09.22.
//

import SwiftUI


struct KeyInformation: View {
    
    @State var key: PrivateKey
    @Binding var keyManagerError: KeyManagerError?
    
    var body: some View {
        VStack(alignment: .center) {
            if let error = keyManagerError {
                Text(error.displayDescription)
                    .alertText()
            }
            HStack {
                Image(systemName: "key.fill")
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(key.name)")
                        .font(.largeTitle)
                    
                    Text("\(key.keyString)")
                    
                    Text("Created \(DateUtils.dateOnlyString(from: key.creationDate))")
                        .font(.caption)
                    Text("Key length: \(key.keyBytes.count)")
                }.padding()
            }
            Spacer()
        }
    }
}

struct KeyInformation_Previews: PreviewProvider {
    static var previews: some View {
        KeyInformation(key: DemoPrivateKey.dummyKey(), keyManagerError: .constant(nil))
    }
}
