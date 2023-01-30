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
            
            deleteActionError = L10n.ErrorDeletingKey.pleaseTryAgain
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
                    deleteActionError = L10n.ErrorDeletingKeyAndAssociatedFiles.pleaseTryAgainOrTryToDeleteFilesManuallyViaTheFilesApp
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
                    Button(L10n.setActive) {
                        viewModel.setActive()
                        dismiss()
                    }
                    NavigationLink {
                        KeyInformation(key: viewModel.key, keyManagerError: .constant(nil))
                    } label: {
                        Text(L10n.keyInfo)
                    }
                    NavigationLink {
                        KeyExchange(viewModel: .init(key: viewModel.key))
                    } label: {
                        Text(L10n.shareKey)
                    }
                    
                    Button(L10n.copyToClipboard) {
                        let key = viewModel.key.base64String
                        let pasteboard = UIPasteboard.general
                        pasteboard.string = key
                        isShowingAlertForCopyKey = true
                    }
                    Button {
                        isShowingAlertForClearKey = true
                    } label: {
                        Text(L10n.deleteKey)
                            .foregroundColor(.red)
                    }
                    Button {
                        isShowingAlertForDeleteAllKeyData = true
                    } label: {
                        Text(L10n.deleteAllKeyData)
                            .foregroundColor(.red)
                    }
                }.listRowBackground(Color.foregroundSecondary)
            }  
            .frame(height: 300)
            .fontType(.small)
            .scrollContentBackgroundColor(Color.background)
            
        }
        .foregroundColor(.blue)
        .alert(L10n.copiedToClipboard, isPresented: $isShowingAlertForCopyKey, actions: {
            Button(L10n.ok) {
                isShowingAlertForCopyKey = false
            }
        }, message: {
            Text(L10n.KeyCopiedToClipboard.storeThisInAPasswordManagerOrOtherSecurePlace)
        })
        .alert(L10n.deleteAllAssociatedData, isPresented: $isShowingAlertForDeleteAllKeyData, actions: {
            if #available(iOS 16.0, *) {
                TextField(L10n.keyName, text: $viewModel.deleteKeyConfirmation)
                    .noAutoModification()
            }
            Button(L10n.deleteEverything, role: .destructive) {
                if viewModel.canDeleteKey() {
                    viewModel.deleteAllKeyData()
                    dismiss()
                }
            }
            Button(L10n.cancel, role: .cancel) {
                isShowingAlertForClearKey = false
            }
        }, message: {
            if #available(iOS 16.0, *) {
                Text(L10n.enterTheNameOfTheKeyToDeleteAllItsDataIncludingSavedMediaForever)
            } else {
                Text(L10n.doYouWantToDeleteThisKeyAndAllMediaAssociatedWithItForever)
            }
            
        })
        .alert(L10n.deleteKeyQuestion, isPresented: $isShowingAlertForClearKey, actions: {
            if #available(iOS 16.0, *) {
                TextField(L10n.keyName, text: $viewModel.deleteKeyConfirmation)
                    .noAutoModification()
            }
            Button(L10n.delete, role: .destructive) {
                if viewModel.canDeleteKey() {
                    viewModel.deleteKey()
                    dismiss()
                }
            }
            Button(L10n.cancel, role: .cancel) {
                isShowingAlertForClearKey = false
            }
        }, message: {
            if #available(iOS 16.0, *) {
                Text(L10n.EnterTheNameOfTheKeyToDeleteItForever.allMediaWillRemainSaved)
            } else {
                Text(L10n.doYouWantToDeleteThisKeyForeverAllMediaWillRemainSaved)
            }
        })
        .alert(L10n.deletionError, isPresented: $viewModel.showDeleteActionError, actions: {
            Button(L10n.ok) {
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
