//
//  StorageOptionSquare.swift
//  Encamera
//
//  Created by Alexander Freas on 03.12.23.
//

import SwiftUI
import EncameraCore

private enum Constants {
    static let cornerRadius: CGFloat = 8.0
}

extension StorageType {

    var iconImage: Image {
        switch self {
        case .icloud:
            return Image("Storage-iCloud")
        case .local:
            return Image("Storage-LocalFolder")
        }
    }
}

struct StorageOptionSquare: View {

    var storageType: StorageType
    @Binding var isSelected: Bool
    var isAvailable: Bool

    var body: some View {
        
        HStack(alignment: .center) {
            storageType.iconImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
            Spacer()
                .frame(width: 24)
            VStack(alignment: .leading) {
                Group {
                    Text(storageType.title)
                        .fontType(.pt16, on: isSelected ? .selectedStorageButton : .background, weight: .bold)
                    Text(storageType.description)
                        .fontType(.pt14, on: isSelected ? .selectedStorageButton : .background)

                }
            }
            Spacer()
        }.padding(16)
            .frame(maxWidth: .infinity)
            .frame(height: 78)
        .optionItem(isSelected: isSelected, isAvailable: isAvailable)

    }
}

#Preview {
    GeometryReader { geo in
        VStack(spacing: 20) {
            let availabilites = DataStorageAvailabilityUtil.storageAvailabilities()
            let moreAvailabilities = availabilites
            ForEach(moreAvailabilities) { storage in
                StorageOptionSquare(storageType: storage.storageType, isSelected: .constant(true), isAvailable: true)
                    .frame(width: geo.size.width - 20, height: 200)
            }
        }
    }
}
