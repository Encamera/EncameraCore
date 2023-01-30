//
//  AddExchangedKeyConfirmation.swift
//  Encamera
//
//  Created by Alexander Freas on 09.09.22.
//

import SwiftUI
import EncameraCore

class AddExchangedKeyConfirmationViewModel: ObservableObject {
    
    var key: PrivateKey
    var selectedStorageType: StorageType?
    var keyManager: KeyManager
    
    init(key: PrivateKey, keyManager: KeyManager) {
        self.key = key
        self.keyManager = keyManager
    }
    
    func saveKeyToManager() throws {
        guard let storageType = selectedStorageType else {
            return
        }
        try keyManager.save(key: key, storageType: storageType, setNewKeyToCurrent: true)
        
    }
    
    
}

struct AddExchangedKeyConfirmation: View {
    
    @StateObject var viewModel: AddExchangedKeyConfirmationViewModel
    
    var body: some View {
        VStack {
            
            Text(L10n.keyName(viewModel.key.name))
            Text(L10n.creationDate(DateUtils.dateOnlyString(from: viewModel.key.creationDate)))
            
            Button {
                
            } label: {
                Text(L10n.saveKey)
            }

            
            
        }
        .navigationTitle(L10n.confirmAddingKey)
    }
}

struct AddExchangedKeyConfirmation_Previews: PreviewProvider {
    static var previews: some View {
        AddExchangedKeyConfirmation(viewModel: .init(key: DemoPrivateKey.dummyKey(), keyManager: DemoKeyManager()))
    }
}
