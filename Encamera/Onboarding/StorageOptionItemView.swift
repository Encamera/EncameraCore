//
//  StorageOptionItemView.swift
//  Encamera
//
//  Created by Alexander Freas on 08.08.22.
//

import SwiftUI
import EncameraCore

struct StorageTypeOptionItemView: View {
    let storageType: StorageType
    let availability: StorageType.Availability
    @Binding var isSelected: Bool

    var body: some View {
        if case .unavailable(let unavailableReason) = availability {
            OptionItemView(title: storageType.title, 
                           description: storageType.description,
                           isAvailable: false,
                           unavailableReason: unavailableReason,
                           isSelected: $isSelected)
        } else {
            OptionItemView(title: storageType.title,
                           description: storageType.description,
                           isAvailable: true,
                           unavailableReason: nil,
                           isSelected: $isSelected)
        }

    }
}

struct StorageOptionItemView_Previews: PreviewProvider {
    static var selectedValue: StorageType = .local
    
    static var previews: some View {
        
        VStack {
            ForEach(StorageType.allCases) { data in
                let selected = Binding {
                    return selectedValue == data
                } set: { newVlue in
                    selectedValue = data
                }
                StorageTypeOptionItemView(storageType: data, availability: .available, isSelected: selected)
            }
        }.padding()
            .previewDevice("iPhone 8")
    }
}
