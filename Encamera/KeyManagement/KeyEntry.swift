//
//  KeyEntry.swift
//  Encamera
//
//  Created by Alexander Freas on 15.11.21.
//

import SwiftUI
import Combine

struct KeyEntry: View {
    
    class ViewModel: ObservableObject {
        @Published var enteredKeyString: String = "" {
            didSet {
                guard let matchedKey = try? PrivateKey(base64String: enteredKeyString) else {
                    return
                }
                self.enteredKey = matchedKey
            }
        }
        @Published var keyStorageType: StorageType = .local
        @Published var enteredKey: PrivateKey?
        private var cancellables = Set<AnyCancellable>()
        var keyManager: KeyManager
        init(enteredKeyString: String = "", keyStorageType: StorageType = .local, enteredKey: PrivateKey? = nil, keyManager: KeyManager) {
            self.enteredKeyString = enteredKeyString
            self.keyStorageType = keyStorageType
            self.enteredKey = (try? PrivateKey(base64String: enteredKeyString)) ?? enteredKey
            self.keyManager = keyManager
            UITextView.appearance().backgroundColor = .clear
        }
        
        func saveKey() {
            do {
                guard let enteredKey = enteredKey else {
                    return
                }
                
                try keyManager.save(key: enteredKey, storageType: keyStorageType)
            } catch {
                
            }
        }
    }
        
    @StateObject var viewModel: ViewModel
    
    init(viewModel: ViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        UITextView.appearance().backgroundColor = .orange
    }
    
    var body: some View {
        
//        GeometryReader { geo in
//            let frame = geo.frame(in: .local)
            VStack(alignment: .center) {
                if let matchedKey = viewModel.enteredKey {
                VStack(alignment: .leading) {
                    Text("\(matchedKey.name)")
                    Text("\(DateUtils.dateOnlyString(from: matchedKey.creationDate))")
                    Text("Key Length: \(matchedKey.keyBytes.count)")
                }//.frame(width: frame.width * 0.8)

                } else {
//                    let keyEdge = frame.width - 50
//                    HStack {
//                        Spacer()
                    ZStack {
                        TextEditor(text: $viewModel.enteredKeyString)
                        
                            .border(Color.black, width: 4)
                            .background(content: {
                                Color.red
                            })
                            
                            .padding()
                        if $viewModel.enteredKeyString.wrappedValue.count == 0 {
                            Text("Paste the private key here.")
                        }
                    }
                    .foregroundColor(.white)
                    .background(Color.black)

                Spacer()
//                        Spacer()
                    }
//                }
//            }
        }
//        .foregroundColor(.white)
//        .background(Color.black)
        .navigationTitle("Key Entry")
        .toolbar {
            if viewModel.enteredKey != nil {
                Button("Save Key") {
                    viewModel.saveKey()
                }
            }
        }
        
//        let keyObject: Binding<PrivateKey?> = {
//            return Binding {
//                return try? PrivateKey(base64String: viewModel.keyString)
//            } set: { _ in
//
//            }
//        }()
//        VStack {
//            if let keyObject = keyObject.wrappedValue {
//                Text("Found key: \(keyObject.name)")
//            }
//
//            TextEditor(text: $viewModel.keyString)
//            Spacer()
//            StorageSettingView(viewModel: .init(keyStorageType: $viewModel.keyStorageType))
//        }.padding().navigationTitle("Key Entry")
//            .toolbar {
//                ToolbarItemGroup(placement: .navigationBarTrailing) {
//                    if viewModel.keyString.count > 0, keyObject.wrappedValue != nil {
//                        Button("Save") {
//                            viewModel.isShowingAlertForSaveKey = true
//                        }
//                    }
//                }
//            }.onAppear {
//                viewModel.keyString = keyObject.wrappedValue?.base64String ?? ""
//            }.alert("Are you sure you want to save this key?", isPresented: $viewModel.isShowingAlertForSaveKey) {
//                Button("Yes", role: .destructive) {
//                    guard let keyObject = keyObject.wrappedValue else {
//                        return
//                    }
//                    try? viewModel.keyManager.save(key: keyObject, storageType: viewModel.keyStorageType)
//                }
//                Button("Cancel", role: .cancel) {
//                    viewModel.isShowingAlertForSaveKey = false
//                }
//            }
    }
}

struct KeyEntry_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            KeyEntry(viewModel: KeyEntry.ViewModel(
//                enteredKeyString: "",

                enteredKeyString: "eyJuYW1lIjoiODhGNTA5MjktNTYxQS00MkQyLTlBRkUtQzM5NjUxNDBDOTQ2Iiwia2V5Qnl0ZXMiOls3MCwxLDY1LDExMCw2OSwxMDAsMjMwLDE4MywxODYsNDEsNzYsMTMyLDQwLDg2LDIyMSwxOTksMjE2LDE4MSw3OSwxNzYsMTM2LDQ3LDIxNywxMTgsMjI0LDEwMywxMDQsMTAsNDksMTg3LDEwMCwxM10sImNyZWF0aW9uRGF0ZSI6Njg0NDAzMjc2LjM5OTM0ODAyfQ=",
                keyStorageType: .local,
                keyManager: MultipleKeyKeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager())))
        }
    }
}
