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
    @Published var blurImages = true
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
        if #available(iOS 16.0, *) {
            return deleteKeyConfirmation == key.name
        } else {
            return true
        }
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
        GalleryGridView(viewModel: .init(privateKey: viewModel.key, blurImages: viewModel.blurImages)) {
            let list = List {
                Group {
                    Button("Set Active") {
                        viewModel.setActive()
                        dismiss()
                    }
                    NavigationLink {
                        KeyInformation(key: viewModel.key, keyManagerError: .constant(nil))
                    } label: {
                        Text("Key Info")
                    }
                    NavigationLink {
                        KeyExchange(viewModel: .init(key: viewModel.key))
                    } label: {
                        Text("Share Key")
                    }
                    
                    Button("Copy to clipboard") {
                        let key = viewModel.key.base64String
                        let pasteboard = UIPasteboard.general
                        pasteboard.string = key
                    }
                    Button {
                        isShowingAlertForClearKey = true
                    } label: {
                        Text("Delete")
                            .foregroundColor(.red)
                    }
                }.listRowBackground(Color.foregroundSecondary)
            }
                
            .frame(height: 300)
            .fontType(.small)
            .background(Color.background)
            
            if #available(iOS 16.0, *) {
                 list.scrollContentBackground(.hidden)
            } else {
                 list
            }
        }
        .foregroundColor(.blue)
        .alert("Delete Key?", isPresented: $isShowingAlertForClearKey, actions: {
            if #available(iOS 16.0, *) {
                TextField("Key name", text: $viewModel.deleteKeyConfirmation)
                    .noAutoModification()
            }
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
            if #available(iOS 16.0, *) {
                Text("Enter the name of the key to delete it forever.")
            } else {
                Text("Do you want to delete this key forever?")
            }
            
        })
    }
}

struct KeyPickerView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            
            KeyDetailView(viewModel: .init(keyManager: DemoKeyManager(), key: PrivateKey(name: "whoop", keyBytes: [], creationDate: Date())))
        }
    }
}
