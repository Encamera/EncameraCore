//
//  KeyPickerView.swift
//  encamera
//
//  Created by Alexander Freas on 09.11.21.
//

import SwiftUI
import EncameraCore

class KeyDetailViewModel: ObservableObject {
    
    enum KeyViewerError {
        case couldNotSetKeychain
    }
    
    @Published var keyManager: KeyManager
    @Published var keyViewerError: KeyViewerError?
    @Published var deleteKeyConfirmation: String = ""
    @Published var blurImages = true
    @Published var deleteActionError: String = ""
    @Published var showDeleteActionError = false
    var fileManager: FileAccess
    var key: PrivateKey
    
    init(keyManager: KeyManager, key: PrivateKey, fileManager: FileAccess) {
        self.keyManager = keyManager
        self.fileManager = fileManager
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
        } catch {
            
            deleteActionError = "Error deleting key. Please try again."
            showDeleteActionError = true
            debugPrint("Error clearing keychain", error)

        }
    }
    
    func deleteAllKeyData() {
        Task {
            do {
                try await fileManager.deleteMedia(for: key)
                try keyManager.deleteKey(key)
            } catch {
                await MainActor.run {
                    deleteActionError = "Error deleting key and associated files. Please try again or try to delete files manually via the Files app."
                    showDeleteActionError = true
                    debugPrint("Error deleting all files")
                
                }
            }
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
    @State var isShowingAlertForDeleteAllKeyData: Bool = false
    @State var isShowingAlertForCopyKey: Bool = false
    @StateObject var viewModel: KeyDetailViewModel
    
    @Environment(\.dismiss) var dismiss
    
    private struct Constants {
        static var outerPadding = 20.0
    }
    var body: some View {
        GalleryGridView(viewModel: .init(privateKey: viewModel.key, blurImages: viewModel.blurImages)) {
            List {
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
                        isShowingAlertForCopyKey = true
                    }
                    Button {
                        isShowingAlertForClearKey = true
                    } label: {
                        Text("Delete Key")
                            .foregroundColor(.red)
                    }
                    Button {
                        isShowingAlertForDeleteAllKeyData = true
                    } label: {
                        Text("Delete All Key Data")
                            .foregroundColor(.red)
                    }
                }.listRowBackground(Color.foregroundSecondary)
            }  
            .frame(height: 300)
            .fontType(.small)
            .scrollContentBackgroundColor(Color.background)
            
        }
        .foregroundColor(.blue)
        .alert("Copied to Clipboard", isPresented: $isShowingAlertForCopyKey, actions: {
            Button("OK") {
                isShowingAlertForCopyKey = false
            }
        }, message: {
            Text("Key copied to clipboard. Store this in a password manager or other secure place.")
        })
        .alert("Delete All Associated Data?", isPresented: $isShowingAlertForDeleteAllKeyData, actions: {
            if #available(iOS 16.0, *) {
                TextField("Key name", text: $viewModel.deleteKeyConfirmation)
                    .noAutoModification()
            }
            Button("Delete Everything", role: .destructive) {
                if viewModel.canDeleteKey() {
                    viewModel.deleteAllKeyData()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {
                isShowingAlertForClearKey = false
            }
        }, message: {
            if #available(iOS 16.0, *) {
                Text("Enter the name of the key to delete all its data, including saved media, forever.")
            } else {
                Text("Do you want to delete this key and all media associated with it forever?")
            }
            
        })
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
                Text("Enter the name of the key to delete it forever. All media will remain saved.")
            } else {
                Text("Do you want to delete this key forever? All media will remain saved.")
            }
        })
        .alert("Deletion Error", isPresented: $viewModel.showDeleteActionError, actions: {
            Button("OK") {
                viewModel.showDeleteActionError = false
            }
        }, message: {
            Text(viewModel.deleteActionError)
        })
    }
}

struct KeyPickerView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {

            KeyDetailView(viewModel: .init(keyManager: DemoKeyManager(), key: PrivateKey(name: "whoop", keyBytes: [], creationDate: Date()), fileManager: DemoFileEnumerator()))
        }
    }
}
