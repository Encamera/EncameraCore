//
//  KeyEntry.swift
//  Shadowpix
//
//  Created by Alexander Freas on 15.11.21.
//

import SwiftUI

struct KeyEntry: View {
    
    @State var keyString = ""
    @Binding var isShowing: Bool
    @EnvironmentObject var state: ShadowPixState
    @State var isShowingAlertForSaveKey: Bool = false

    var body: some View {
        let keyObject: Binding<ImageKey?> = {
            return Binding {
                return try? ImageKey(base64String: keyString)
            } set: { _ in
                
            }
        }()
        NavigationView {
            VStack {
                if let keyObject = keyObject.wrappedValue {
                    Text("Found key: \(keyObject.name)")
                }
                
                TextEditor(text: $keyString)
                Spacer()
                
            }.padding().navigationTitle("Key Entry")
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            isShowing = false
                        }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if keyString.count > 0, keyObject.wrappedValue != nil {
                            Button("Save") {
                                isShowingAlertForSaveKey = true
                                }
                        }
                    }
                }
        }.onAppear {
            keyString = keyObject.wrappedValue?.base64String ?? ""
        }.alert("Are you sure you want to save this key?", isPresented: $isShowingAlertForSaveKey) {
            Button("Yes", role: .destructive) {
                guard let keyObject = keyObject.wrappedValue else {
                    return
                }
                state.selectedKey = keyObject
                state.scannedKey = nil
                isShowing = false
            }
            Button("Cancel", role: .cancel) {
                isShowingAlertForSaveKey = false
            }
        }
    }
}

struct KeyEntry_Previews: PreviewProvider {
    static var previews: some View {
        KeyEntry( keyString: "eyJrZXlEYXRhIjoiQ00wUjJIdkZkdzczM3pZbGFSKzh2cXd6SW90MitRZjFEbDFZN1FFUE8zYz0iLCJuYW1lIjoidGVzdCJ9", isShowing: .constant(true))
            .environmentObject(ShadowPixState(fileHandler: DemoFileEnumerator()))
    }
}
