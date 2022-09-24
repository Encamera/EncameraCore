//
//  StorageOptionItemView.swift
//  Encamera
//
//  Created by Alexander Freas on 08.08.22.
//

import SwiftUI

struct StorageTypeOptionItemView: View {
    
    let storageType: StorageType
    let availability: StorageType.Availability
    @Binding var isSelected: Bool
    
    
    var body: some View {
        let background = RoundedRectangle(cornerRadius: 16, style: .continuous)
        
        let iconWithName = HStack {
            ZStack(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .foregroundColor(Color.activeKey)
                        
                        .frame(width: 20, height: 20)
                        .offset(x: -7, y: 7)
                }
                VStack {
                    Image(systemName: storageType.iconName).resizable()
                        .aspectRatio(contentMode: .fit)
                    Text(storageType.title)
                        
                }.padding().frame(width: 100, height: 100)
                    .overlay(background.stroke(Color.foregroundSecondary, lineWidth: 3))
                
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if case .unavailable(_) = availability {
                    iconWithName.opacity(0.3)
                } else {
                    iconWithName
                }
                Spacer().frame(width: 10)
                VStack(spacing: 10) {
                    if case .unavailable(let unavailableReason) = availability {
                        Text(unavailableReason)
                            .alertText()
                    } else {
                        Text(storageType.description)
                    }
                }
                Spacer()
                
            }.fixedSize(horizontal: false, vertical: true)
        }
        .fontType(.small)
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
                StorageTypeOptionItemView(storageType: data, availability: data == .icloud ? .unavailable(reason: "Unavailable: iCloud needs to be verified in the Settings app.") : .available, isSelected: selected)
            }
        }.padding()
            .previewDevice("iPhone 8")
    }
}
