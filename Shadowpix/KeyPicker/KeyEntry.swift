//
//  KeyEntry.swift
//  Shadowpix
//
//  Created by Alexander Freas on 15.11.21.
//

import SwiftUI
import Combine

struct KeyEntry: View {
    
    class ViewModel: ObservableObject {
        var keyManager: KeyManager
        init(keyManager: KeyManager, isShowing: Binding<Bool>) {
            self.keyManager = keyManager
        }
    }
    
    @State private var keyString = ""
    
    @EnvironmentObject var state: ShadowPixState
    @State var isShowingAlertForSaveKey: Bool = false
    
    private var viewModel: ViewModel
    
    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        let keyObject: Binding<ImageKey?> = {
            return Binding {
                return try? ImageKey(base64String: keyString)
            } set: { _ in
                
            }
        }()
        NavigationView {
            VStack {
                if let keyObject = keyObject.wrappedValue {
                    Text("Found key: \(keyObject.name)")
                }
                
                TextEditor(text: $keyString)
                Spacer()
                
            }.padding().navigationTitle("Key Entry")
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if keyString.count > 0, keyObject.wrappedValue != nil {
                            Button("Save") {
                                isShowingAlertForSaveKey = true
                                }
                        }
                    }
                }
        }.onAppear {
            keyString = keyObject.wrappedValue?.base64String ?? ""
        }.alert("Are you sure you want to save this key?", isPresented: $isShowingAlertForSaveKey) {
            Button("Yes", role: .destructive) {
                guard let keyObject = keyObject.wrappedValue else {
                    return
                }
                try? viewModel.keyManager.save(key: keyObject)
            }
            Button("Cancel", role: .cancel) {
                isShowingAlertForSaveKey = false
            }
        }
    }
}

struct KeyEntry_Previews: PreviewProvider {
    static var previews: some View {
        KeyEntry(viewModel: KeyEntry.ViewModel(keyManager: KeychainKeyManager(isAuthorized: Just(true).eraseToAnyPublisher()), isShowing: .constant(true)))
    }
}
