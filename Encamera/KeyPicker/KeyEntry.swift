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
        @Published var keyString: String = ""
        @Published var isShowingAlertForSaveKey: Bool = false
        @Published var keyStorageType: StorageType = .local
        @Published var storageAvailabilities: [StorageAvailabilityModel] = []
        var keyManager: KeyManager
        init(keyManager: KeyManager, isShowing: Binding<Bool>) {
            self.keyManager = keyManager
        }
        
        func loadStorageAvailabilities() {
            Task {
                var availabilites = [StorageAvailabilityModel]()
                for type in StorageType.allCases {
                    let result = await keyManager.keyDirectoryStorage.isStorageTypeAvailable(type: type)
                    availabilites += [StorageAvailabilityModel(storageType: type, availability: result)]
                }
                await setStorage(availabilites: availabilites)
            }
            
        }
        @MainActor
        func setStorage(availabilites: [StorageAvailabilityModel]) async {
            await MainActor.run {
                self.keyStorageType = availabilites.filter({
                    if case .available = $0.availability {
                        return true
                    }
                    return false
                }).map({$0.storageType}).first ?? .local
                self.storageAvailabilities = availabilites
            }
        }
    }
        
    @StateObject var viewModel: ViewModel
    
    
    var body: some View {
        let keyObject: Binding<PrivateKey?> = {
            return Binding {
                return try? PrivateKey(base64String: viewModel.keyString)
            } set: { _ in
                
            }
        }()
        VStack {
            if let keyObject = keyObject.wrappedValue {
                Text("Found key: \(keyObject.name)")
            }
            
            TextEditor(text: $viewModel.keyString)
            Spacer()
            StorageSettingView(keyStorageType: $viewModel.keyStorageType, storageAvailabilities: $viewModel.storageAvailabilities)
        }.padding().navigationTitle("Key Entry")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if viewModel.keyString.count > 0, keyObject.wrappedValue != nil {
                        Button("Save") {
                            viewModel.isShowingAlertForSaveKey = true
                        }
                    }
                }
            }.onAppear {
                viewModel.keyString = keyObject.wrappedValue?.base64String ?? ""
            }.alert("Are you sure you want to save this key?", isPresented: $viewModel.isShowingAlertForSaveKey) {
                Button("Yes", role: .destructive) {
                    guard let keyObject = keyObject.wrappedValue else {
                        return
                    }
                    try? viewModel.keyManager.save(key: keyObject, storageType: viewModel.keyStorageType)
                }
                Button("Cancel", role: .cancel) {
                    viewModel.isShowingAlertForSaveKey = false
                }
            }.onAppear {
                viewModel.loadStorageAvailabilities()
            }
    }
}

struct KeyEntry_Previews: PreviewProvider {
    static var previews: some View {
        KeyEntry(viewModel: KeyEntry.ViewModel(keyManager: MultipleKeyKeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager()), isShowing: .constant(true)))
    }
}
