//
//  KeyPickerView.swift
//  encamera
//
//  Created by Alexander Freas on 09.11.21.
//

import SwiftUI

class KeyDetailViewModel: ObservableObject {
    
    enum KeyViewerError {
        case couldNotSetKeychain
    }
    
    @Published var keyManager: KeyManager
    @Published var isShowingAlertForClearKey: Bool = false
    @Published var keyViewerError: KeyViewerError?
    @Published var deleteKeyConfirmation: String = ""
    var key: PrivateKey
    
    init(keyManager: KeyManager, key: PrivateKey) {
        self.keyManager = keyManager
        self.key = key
    }
    
    func setActive() {
        do {
            try keyManager.setActiveKey(key.name)
        } catch {
            keyViewerError = .couldNotSetKeychain
        }
    }
    
    func deleteKey() {
        do {
            try keyManager.deleteKey(key)
            isShowingAlertForClearKey = false
        } catch {
            debugPrint("Error clearing keychain", error)
        }
    }
    
    func canDeleteKey() -> Bool {
        deleteKeyConfirmation == key.name
    }
}

struct KeyDetailView: View {
    
    @State var isShowingAlertForClearKey: Bool = false
    @StateObject var viewModel: KeyDetailViewModel
    
    @Environment(\.dismiss) var dismiss
    
    private struct Constants {
        static var outerPadding = 20.0
    }
    var body: some View {
        GalleryGridView(viewModel: .init(privateKey: viewModel.key)) {
            List {
                Button("Set Active") {
                    viewModel.setActive()
                    dismiss()
                }
                NavigationLink {
                    KeyExchange(viewModel: .init(key: viewModel.key))
                } label: {
                    Button("Share Key") {
                        
                    }
                }

                
                Button {
                    isShowingAlertForClearKey = true
                } label: {
                    Text("Delete")
                        .foregroundColor(.red)
                }
            }.frame(height: 200)
        }
        .foregroundColor(.blue)
        .alert("Delete Key?", isPresented: $isShowingAlertForClearKey, actions: {
            TextField("Key name", text: $viewModel.deleteKeyConfirmation)
                .noAutoModification()
            Button("Delete", role: .destructive) {
                if viewModel.canDeleteKey() {
                    viewModel.deleteKey()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {
                isShowingAlertForClearKey = false
            }
        }, message: {
            Text("Enter the name of the key to delete it forever.")
        })
    }
}

struct KeyPickerView_Previews: PreviewProvider {
    static var previews: some View {
        KeyDetailView(viewModel: .init(keyManager: DemoKeyManager(), key: PrivateKey(name: "whoop", keyBytes: [], creationDate: Date())))
            .preferredColorScheme(.dark)
    }
}
