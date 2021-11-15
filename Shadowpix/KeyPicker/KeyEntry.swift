//
//  KeyEntry.swift
//  Shadowpix
//
//  Created by Alexander Freas on 15.11.21.
//

import SwiftUI

struct KeyEntry: View {
    
    @State private var keyString = ""
    @Binding var isShowing: Bool
    
    var body: some View {
        NavigationView {
            VStack {
                TextField("Enter base64 encoded key", text: $keyString)
                Spacer()
                
            }.padding().navigationTitle("Key Entry")
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            isShowing = false
                        }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if keyString.count > 0, let imageKey = try? ImageKey(base64String: keyString) {
                            Button("Save") {
                                WorkWithKeychain.setKey(key: imageKey)
                                isShowing = false
                            }
                        }
                    }
                }
        }
    }
}

struct KeyEntry_Previews: PreviewProvider {
    static var previews: some View {
        KeyEntry(isShowing: .constant(true))
    }
}
