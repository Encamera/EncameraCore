//
//  KeySelectionCell.swift
//  Encamera
//
//  Created by Alexander Freas on 23.06.22.
//

import SwiftUI
import EncameraCore

class KeySelectionCellViewModel: ObservableObject {
    
    var isActive: Bool
    var key: PrivateKey
    var imageCount: Int
    
    init(key: PrivateKey, isActive: Bool, imageCount: Int) {
        self.isActive = isActive
        self.key = key
        self.imageCount = imageCount
    }
}

struct KeySelectionCell: View {
    
    @StateObject var viewModel: KeySelectionCellViewModel
    
    var body: some View {
        HStack {
            HStack {
                Text("\(viewModel.imageCount)")
                    .fontType(.small)
                    .frame(width: 30)
                VStack(alignment: .leading) {
                    Text(viewModel.key.name)
                        .fontType(.medium)
                    if viewModel.isActive {
                        Text("Active")
                            .foregroundColor(.activeKey)
                            .fontType(.small)
                    }
                    Text(DateUtils.dateOnlyString(from: viewModel.key.creationDate))
                        .fontType(.small)
                }
                Spacer()
            }.padding()
            if viewModel.isActive {
                HStack {
                    Image(systemName: "key.fill")
                }
                .foregroundColor(.activeKey)
                
            } else {
                Image(systemName: "key")
            }
        }.fontType(.small)
    }
}

struct KeySelectionCell_Previews: PreviewProvider {
    static var previews: some View {
        KeySelectionCell(viewModel: .init(key: PrivateKey(name: "secrets", keyBytes: [], creationDate: Date()), isActive: true, imageCount: 32))
    }
}
