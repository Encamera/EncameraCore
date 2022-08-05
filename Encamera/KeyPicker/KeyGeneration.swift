//
//  KeyGeneration.swift
//  Encamera
//
//  Created by Alexander Freas on 14.11.21.
//

import SwiftUI

class KeyGenerationViewModel: ObservableObject {
    @Published var keyName: String = ""
    @Published var keyManagerError: KeyManagerError?
    @Published var storageType: StorageType = .local
    var keyManager: KeyManager
    
    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }
    
    func saveKey() {
        do {
            try keyManager.generateNewKey(name: keyName, storageType: storageType)
        } catch {
            guard let keyError = error as? KeyManagerError else {
                return
            }
            self.keyManagerError = keyError
        }
    }
}

struct KeyGeneration: View {
    @ObservedObject var viewModel: KeyGenerationViewModel
    @FocusState var isFocused: Bool
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack {
            
            TextField("Key Name", text: $viewModel.keyName, prompt: Text("Key Name"))
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .frame(height: 44)
                .focused($isFocused)
            Spacer()
            
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if viewModel.keyName.count > 0 {
                    
                    Button("Save") {
                        saveKey()
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
    
    func saveKey() {
        viewModel.saveKey()
        dismiss()
    }
}

struct KeyGeneration_Previews: PreviewProvider {
    static var previews: some View {
        KeyGeneration(viewModel: .init(keyManager: DemoKeyManager()))
    }
}
