//
//  KeySelectionCell.swift
//  Encamera
//
//  Created by Alexander Freas on 23.06.22.
//

import SwiftUI

class KeySelectionCellViewModel: ObservableObject {
    
    var isActive: Bool
    var key: PrivateKey
    
    init(key: PrivateKey, isActive: Bool) {
        self.isActive = isActive
        self.key = key
    }
}

struct KeySelectionCell: View {
    
    @StateObject var viewModel: KeySelectionCellViewModel
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(viewModel.key.name)
                    .font(.title)
                Text(DateUtils.dateOnlyString(from: viewModel.key.creationDate))
                    .font(.caption)
            }
            Spacer()
            if viewModel.isActive {
                HStack {
                    Text("Active")
                    Image(systemName: "key.fill")
                }.foregroundColor(.green)
                
            } else {
                Image(systemName: "key")
            }
        }.padding()
    }
}

struct KeySelectionCell_Previews: PreviewProvider {
    static var previews: some View {
        KeySelectionCell(viewModel: .init(key: PrivateKey(name: "test", keyBytes: [], creationDate: Date()), isActive: true))
    }
}
