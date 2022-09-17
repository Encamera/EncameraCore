//
//  KeyEntry.swift
//  Encamera
//
//  Created by Alexander Freas on 15.11.21.
//

import SwiftUI
import Combine

struct KeyEntry: View {
    @Environment(\.dismiss) var dismiss
    
    class ViewModel: ObservableObject {
        @Published var enteredKeyString: String = "" {
            didSet {
                guard let matchedKey = try? PrivateKey(base64String: enteredKeyString) else {
                    return
                }
                self.enteredKey = matchedKey
            }
        }
        var dismiss: Binding<Bool>?
        @Published var keyStorageType: StorageType?
        @Published var enteredKey: PrivateKey?
        @Published var keyManagerError: KeyManagerError?
        @Published var showStorageSelectionSheet = false
        var showCancelButton = false
        private var cancellables = Set<AnyCancellable>()
        var keyManager: KeyManager
        init(enteredKeyString: String = "", keyStorageType: StorageType = .local, enteredKey: PrivateKey? = nil, keyManager: KeyManager, showCancelButton: Bool = false, dismiss: Binding<Bool>? = nil) {
            self.enteredKeyString = enteredKeyString
            self.showCancelButton = showCancelButton
            self.keyStorageType = keyStorageType
            self.enteredKey = (try? PrivateKey(base64String: enteredKeyString)) ?? enteredKey
            self.keyManager = keyManager
            self.dismiss = dismiss
            UITextView.appearance().backgroundColor = .clear
        }
        
        func saveButtonPressed() throws {
            guard let enteredKey = enteredKey else {
                return
            }
            
            if let storageModel = DataStorageUserDefaultsSetting().determineStorageModelFor(keyName: enteredKey.name) {
                keyStorageType = storageModel.storageType
                try saveKey()
            } else {
                showStorageSelectionSheet = true
            }

        }
        
        func saveKey() throws {
            do {
                guard let enteredKey = enteredKey, let storageType = keyStorageType else {
                    return
                }
                
                try keyManager.save(key: enteredKey, storageType: storageType)
            } catch let managerError as KeyManagerError {
                self.keyManagerError = managerError
                throw managerError
            } catch {
                debugPrint("Error saving key", error)
                throw error
            }
        }
    }
    
    @StateObject var viewModel: ViewModel
    
    init(viewModel: ViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        UITextView.appearance().backgroundColor = .clear
    }
    
    var body: some View {
        let vstack = VStack(alignment: .center) {
            if let matchedKey = viewModel.enteredKey {
                KeyInformation(key: matchedKey, keyManagerError: $viewModel.keyManagerError)
            } else {
                ZStack {
                    TextEditor(text: $viewModel.enteredKeyString)
                        .padding()
                    if $viewModel.enteredKeyString.wrappedValue.count == 0 {
                        Text("Paste the private key here.")
                    }
                }
                .background(Color.gray)
                .padding()
                Spacer()
            }
        }
            .sheet(isPresented: $viewModel.showStorageSelectionSheet) {
                let view =  NavigationView {
                    
                    VStack {
                        Text("Where do you want to save this key's media?")
                            .font(.headline)
                        StorageSettingView(viewModel: .init(), keyStorageType: $viewModel.keyStorageType).padding()
                        
                    }.toolbar {
                        Button("Save") {
                            do {
                                try viewModel.saveKey()
                                viewModel.showStorageSelectionSheet = false
                                dismissAction()
                            } catch {
                                viewModel.showStorageSelectionSheet = false
                            }
                        }
                    }
                }
                if #available(iOS 16.0, *) {
                    view.presentationDetents([.medium])
                } else {
                    view
                }
                
            }
            .frame(maxWidth: .infinity)
            .navigationTitle("Key Entry")
        
        if viewModel.showCancelButton {
            vstack.toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismissAction()
                    }
                }
                saveKeyToolbar
            }
            
        } else {
            vstack.toolbar {
                saveKeyToolbar
            }
        }
    }
    
    private func dismissAction() {
        if let dismissBinding = viewModel.dismiss {
            dismissBinding.wrappedValue = true
        } else {
            dismiss()
        }
    }
    private var saveKeyToolbar: ToolbarItemGroup<some View> {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if viewModel.enteredKey != nil {
                Button("Save Key") {
                    do {
                        try viewModel.saveButtonPressed()
                    } catch {
                        
                    }                    
                }
            }
        }
    }
    
}

struct KeyEntry_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            KeyEntry(viewModel: KeyEntry.ViewModel(
                //                                enteredKeyString: "",
                
                enteredKeyString: "eyJuYW1lIjoiODhGNTA5MjktNTYxQS00MkQyLTlBRkUtQzM5NjUxNDBDOTQ2Iiwia2V5Qnl0ZXMiOls3MCwxLDY1LDExMCw2OSwxMDAsMjMwLDE4MywxODYsNDEsNzYsMTMyLDQwLDg2LDIyMSwxOTksMjE2LDE4MSw3OSwxNzYsMTM2LDQ3LDIxNywxMTgsMjI0LDEwMywxMDQsMTAsNDksMTg3LDEwMCwxM10sImNyZWF0aW9uRGF0ZSI6Njg0NDAzMjc2LjM5OTM0ODAyfQ==",
                keyStorageType: .local,
                keyManager: MultipleKeyKeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager()), dismiss: .constant(true)))
        }
    }
}
