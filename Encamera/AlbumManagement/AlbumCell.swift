//
//  AlbumCell.swift
//  Encamera
//
//  Created by Alexander Freas on 23.06.22.
//

import SwiftUI
import EncameraCore

class AlbumCellViewModel: ObservableObject {
    
    var isActive: Bool
    var key: PrivateKey
    var imageCount: Int
    
    init(key: PrivateKey, isActive: Bool, imageCount: Int) {
        self.isActive = isActive
        self.key = key
        self.imageCount = imageCount
    }
}

struct AlbumCell: View {
    
    @StateObject var viewModel: AlbumCellViewModel
    
    var body: some View {
        HStack {
            HStack {
                Text("\(viewModel.imageCount)")
                    .fontType(.pt18)
                    .frame(width: 30)
                VStack(alignment: .leading) {
                    Text(viewModel.key.name)
                        .fontType(.medium)
                    if viewModel.isActive {
                        Text(L10n.active)
                            .foregroundColor(.activeKey)
                            .fontType(.pt18)
                    }
                    Text(DateUtils.dateOnlyString(from: viewModel.key.creationDate))
                        .fontType(.pt18)
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
        }.fontType(.pt18)
    }
}

struct AlbumCell_Previews: PreviewProvider {
    static var previews: some View {
        AlbumCell(viewModel: .init(key: PrivateKey(name: "secrets", keyBytes: [], creationDate: Date()), isActive: true, imageCount: 32))
    }
}
