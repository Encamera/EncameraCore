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
        @Published var storageType: StorageType = .local
        var keyManager: KeyManager
        init(keyManager: KeyManager, isShowing: Binding<Bool>) {
            self.keyManager = keyManager
        }
    }
        
    @ObservedObject private var viewModel: ViewModel
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        let keyObject: Binding<ImageKey?> = {
            return Binding {
                return try? ImageKey(base64String: viewModel.keyString)
            } set: { _ in
                
            }
        }()
        VStack {
            if let keyObject = keyObject.wrappedValue {
                Text("Found key: \(keyObject.name)")
            }
            
            TextEditor(text: $viewModel.keyString)
            Spacer()
            
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
                    try? viewModel.keyManager.save(key: keyObject, storageType: viewModel.storageType)
                }
                Button("Cancel", role: .cancel) {
                    viewModel.isShowingAlertForSaveKey = false
                }
            }
    }
}

struct KeyEntry_Previews: PreviewProvider {
    static var previews: some View {
        KeyEntry(viewModel: KeyEntry.ViewModel(keyManager: MultipleKeyKeychainManager(isAuthorized: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: ImageKeyDirectoryStorage()), isShowing: .constant(true)))
    }
}
