//
//  KeyGeneration.swift
//  Shadowpix
//
//  Created by Alexander Freas on 14.11.21.
//

import SwiftUI

struct KeyGeneration: View {
    
    @State var isShowingAlertForNewKey: Bool = false
    @State var keyName: String = ""
    @Binding var isShown: Bool
    @EnvironmentObject var appState: ShadowPixState
    @FocusState var isFocused: Bool
    var body: some View {
        NavigationView {
            VStack {
                
                TextField("Key Name", text: $keyName, prompt: Text("Key Name"))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .frame(height: 44)
                    .focused($isFocused)
                Spacer()
                
            }.alert("Are you sure you want to generate a new key?", isPresented: $isShowingAlertForNewKey) {
                Button("Yes", role: .destructive) {
                    saveKey()
                    isShown = false
                }
                Button("Cancel", role: .cancel) {
                    isShowingAlertForNewKey = false
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isShown = false
                    }
                }
                
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if keyName.count > 0 {
                        
                        Button("Save") {
                            if WorkWithKeychain.getKeyObject() == nil {
                                saveKey()
                                isShown = false
                            } else {
                                isShowingAlertForNewKey = true
                            }
                        }.foregroundColor(.blue)
                    }
                }
            }
            .padding()
            .navigationTitle("Key Generation")
            .onAppear {
                isFocused = true
            }
        }
    }
    
    func saveKey() {
        do {
            try ChaChaPolyHelpers.generateNewKey(name: keyName)
            appState.selectedKey = WorkWithKeychain.getKeyObject()
        } catch {
            print("Could not generate new key")
        }
    }
}

struct KeyGeneration_Previews: PreviewProvider {
    static var previews: some View {
        KeyGeneration(isShown: .constant(true))
    }
}
