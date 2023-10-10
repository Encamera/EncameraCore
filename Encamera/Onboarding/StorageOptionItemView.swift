//
//  StorageOptionItemView.swift
//  Encamera
//
//  Created by Alexander Freas on 08.08.22.
//

import SwiftUI
import EncameraCore

private enum Constants {
    static let checkmarkSize = 24.0
    static let checkmarkBorder = 5.0
    static let cornerRadius = 8.0
    static let lineWidth = 1.0
    static let spacing = 4.0
    static let padding = 20.0
    static let opacity = 0.3
    static let offsetMultiplier = 0.5
}

struct StorageTypeOptionItemView: View {

    let storageType: StorageType
    let availability: StorageType.Availability
    @Binding var isSelected: Bool


    @ViewBuilder private var background: some View {
        let rect = RoundedRectangle(cornerRadius: Constants.cornerRadius, style: .continuous)
        let rectangle = rect
            .stroke(Color.secondaryElementColor, lineWidth: Constants.lineWidth)
        if isSelected {
            rectangle.background(rect.fill(Color.white))
        } else {
            rectangle
        }
    }

    var body: some View {
        let iconWithName = HStack {
            ZStack(alignment: .topTrailing) {
                HStack {
                    VStack(alignment: .leading, spacing: Constants.spacing) {
                        Text(storageType.title)
                            .fontType(.pt16, on: isSelected ? .selectedStorageButton : .background, weight: .bold)
                        if case .unavailable(let unavailableReason) = availability {
                            Text(unavailableReason)
                                .alertText()
                        } else {
                            Text(storageType.description)
                                .fontType(.extraSmall, on: isSelected ? .selectedStorageButton : .background)
                        }
                    }
                    Spacer()
                }
                .padding(Constants.padding)
                .frame(maxWidth: .infinity)
                .background(background)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .foregroundColor(Color.actionYellowGreen)
                        .background(Circle().foregroundColor(.black).frame(width: Constants.checkmarkSize + Constants.checkmarkBorder, height: Constants.checkmarkSize + Constants.checkmarkBorder))
                        .frame(width: Constants.checkmarkSize, height: Constants.checkmarkSize)
                        .offset(x: Constants.checkmarkSize * Constants.offsetMultiplier, y: -Constants.checkmarkSize * Constants.offsetMultiplier)
                }
            }
        }
        VStack(alignment: .leading) {
            HStack {
                if case .unavailable(_) = availability {
                    iconWithName.opacity(Constants.opacity)
                } else {
                    iconWithName
                }
            }
        }
        .onTapGesture {
            isSelected = true
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
