//
//  StorageSettingView.swift
//  Encamera
//
//  Created by Alexander Freas on 11.08.22.
//

import SwiftUI

class StorageSettingViewModel: ObservableObject {
    
    @Published var storageAvailabilities: [StorageAvailabilityModel] = DataStorageUserDefaultsSetting().storageAvailabilities()
    
    init(storageAvailabilities: [StorageAvailabilityModel] = DataStorageUserDefaultsSetting().storageAvailabilities()) {
        self.storageAvailabilities = storageAvailabilities
    }
}

struct StorageSettingView: View {
    
    @StateObject var viewModel: StorageSettingViewModel = StorageSettingViewModel()
    @Binding var keyStorageType: StorageType
    var body: some View {
        VStack(spacing: 20) {
            
            ForEach(viewModel.storageAvailabilities) { data in
                let binding = Binding {
                    data.storageType == keyStorageType
                } set: { value in
                    guard case .available = data.availability else {
                        return
                    }
                    keyStorageType = data.storageType
                }
                StorageTypeOptionItemView(
                    storageType: data.storageType,
                    availability: data.availability,
                    isSelected: binding)
            }
        }
        
    }
}

//struct StorageSettingView_Previews: PreviewProvider {
//    static var previews: some View {
//        StorageSettingView(keyStorageType: .constant(.local), storageAvailabilities: .constant([
//            .init(storageType: .local, availability: .available),
//            .init(storageType: .icloud, availability: .unavailable(reason: "No iCloud account found."))]))
//    }
//}
