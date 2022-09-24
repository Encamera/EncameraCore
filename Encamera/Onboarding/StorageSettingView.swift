//
//  StorageSettingView.swift
//  Encamera
//
//  Created by Alexander Freas on 11.08.22.
//

import SwiftUI

class StorageSettingViewModel: ObservableObject {
    
    @Published var storageAvailabilities: [StorageAvailabilityModel] = DataStorageUserDefaultsSetting().storageAvailabilities()
    var keyStorageType: Binding<StorageType?>
    init(keyStorageType: Binding<StorageType?>) {
        self.keyStorageType = keyStorageType
    }
}

struct StorageSettingView: View {
    
    @StateObject var viewModel: StorageSettingViewModel
    var body: some View {
        VStack(spacing: 20) {
            ForEach(viewModel.storageAvailabilities) { data in
                let binding = Binding<Bool> {
                    if data.storageType == viewModel.keyStorageType.wrappedValue {
                        return true
                    }
                    return data.storageType == viewModel.keyStorageType.wrappedValue
                } set: { value in
                    guard value == true,
                          case .available = data.availability else {
                        return
                    }
                    viewModel.keyStorageType.wrappedValue = data.storageType
                }
                StorageTypeOptionItemView(
                    storageType: data.storageType,
                    availability: data.availability,
                    isSelected: binding)
            }
        }
        
    }
}

struct StorageSettingView_Previews: PreviewProvider {
    static var previews: some View {
        StorageSettingView(viewModel: .init(keyStorageType: .constant(.local)))
    }
}
