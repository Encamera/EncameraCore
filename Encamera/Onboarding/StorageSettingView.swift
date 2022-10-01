//
//  StorageSettingView.swift
//  Encamera
//
//  Created by Alexander Freas on 11.08.22.
//

import SwiftUI

class StorageSettingViewModel: ObservableObject {
    
    @Published var storageAvailabilities: [StorageAvailabilityModel] = DataStorageUserDefaultsSetting().storageAvailabilities()
}

struct StorageSettingView: View {
    
    @StateObject var viewModel: StorageSettingViewModel
    var keyStorageType: Binding<StorageType?>

    var body: some View {
        VStack(spacing: 20) {
            ForEach(viewModel.storageAvailabilities) { data in
                let binding = Binding<Bool> {
                    let value = keyStorageType.wrappedValue
                    return data.storageType == value
                } set: { value in
                    guard value == true,
                          case .available = data.availability else {
                        return
                    }
                    keyStorageType.wrappedValue = data.storageType
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
        StorageSettingView(viewModel: .init(), keyStorageType: .constant(.icloud))
    }
}
